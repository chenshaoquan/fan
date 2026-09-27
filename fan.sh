#!/usr/bin/env bash
# 英伟达显卡风扇温控：单文件发行版。
# 此文件内嵌全部程序、默认配置、服务定义和中文说明，不从网络下载代码。
# 使用：sudo bash fan.sh；以后运行 fan 即可打开中文菜单。
set -euo pipefail
export PYTHONIOENCODING=utf-8

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    echo '显卡风扇温控——单文件版'
    echo '用法：sudo bash fan.sh [选项]'
    echo '不带选项：首次安装并打开中文菜单；已安装相同版本时直接打开菜单。'
    echo '--install：仅安装或更新，不打开菜单；保留已有配置。'
    echo '--check：只检查环境和配置，不安装、不修改风扇策略。'
    echo '--help：显示此帮助。'
    echo '安装后输入 fan 打开菜单；输入 fan 帮助 查看中文命令。'
    echo '需要使用系统服务管理器的 Linux、Python 3 和支持风扇控制的英伟达驱动。'
    echo '只需分发这个文件；运行时会自动生成程序文件、配置和后台服务。'
    exit 0
fi
if [[ $# -gt 1 || ( $# -eq 1 && $1 != --check && $1 != --install ) ]]; then
    echo '参数不正确，请使用 --help 查看帮助。' >&2
    exit 1
fi
if [[ $EUID -ne 0 ]]; then
    echo '请以管理员身份运行：sudo bash fan.sh' >&2
    exit 1
fi
umask 077
bundle_dir="$(mktemp -d "${TMPDIR:-/tmp}/nvidia-fan-control.XXXXXXXX")"
cleanup() {
    rm -f -- "$bundle_dir/fan-control.sh" "$bundle_dir/fan_control.py" \
        "$bundle_dir/fan" "$bundle_dir/gpu-fan-control.service" \
        "$bundle_dir/curve.example.json" "$bundle_dir/README.md" "$bundle_dir/install.sh"
    rmdir -- "$bundle_dir" 2>/dev/null || true
}
trap cleanup EXIT


cat > "$bundle_dir/fan-control.sh" <<'FAN_EMBEDDED_PAYLOAD_1_END'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONIOENCODING=utf-8
exec python3 "$SCRIPT_DIR/fan_control.py" "$@"
FAN_EMBEDDED_PAYLOAD_1_END

cat > "$bundle_dir/fan_control.py" <<'FAN_EMBEDDED_PAYLOAD_2_END'
#!/usr/bin/env python3
"""Interactive NVIDIA fan curves, using only Python's standard library and NVML."""
import argparse
import contextlib
import ctypes as C
import fcntl
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

BASE = Path(__file__).resolve().parent
CONFIG = BASE / 'curve.json'
SERVICE = 'gpu-fan-control.service'
DEFAULT = {'speeds': [40, 60, 80, 90, 100], 'idle_stop': True}
THRESHOLDS = [60, 70, 75, 80, 85]
HYSTERESIS = 3
INTERVAL = 3
IDLE_SECONDS = 30
IDLE_ENTER_TEMP = 50
IDLE_EXIT_TEMP = 55
U, H = C.c_uint, C.c_void_p


class Utilization(C.Structure):
    _fields_ = [('gpu', U), ('memory', U)]


HELP_TEXT = '''显卡风扇温控

用法：fan [命令] [参数]
不带参数运行即可打开交互菜单。

常用命令：
  fan 菜单                       打开交互菜单
  fan 状态 [显卡编号]             查看全部显卡或指定显卡
  fan 配置 40 60 80 90 100        设置低温、六十、七十、七十五、八十度档的百分比
  fan 空闲 开启                  开启低温空闲停转
  fan 空闲 关闭                  关闭空闲停转
  fan 启动                       启用温控并设置开机启动
  fan 停止                       停止温控并恢复原厂自动调速
  fan 自动 [显卡编号]             恢复原厂自动调速
  fan 固定 60 [显卡编号]          设置固定转速，需先停止后台温控
  fan 日志                       查看最近的程序日志
  fan 帮助                       显示此帮助

显卡编号从零开始；省略编号或填写“全部”表示全部显卡。
手动转速范围为百分之三十至百分之一百，所有参数使用整数。
原有英文命令仍然兼容。'''


class ChineseParser(argparse.ArgumentParser):
    def error(self, message):
        self.exit(2, '参数错误：请检查命令名称、参数数量和取值。转速应为整数，显卡编号从零开始。\n输入“fan 帮助”查看用法。\n')


def validate(config):
    if not isinstance(config, dict) or set(config) not in ({'speeds'}, {'speeds', 'idle_stop'}):
        raise ValueError('配置格式不正确，应包含转速列表')
    speeds = config['speeds']
    if not isinstance(speeds, list) or len(speeds) not in (4, 5):
        raise ValueError('需要五档转速：低于60°C、60°C、70°C、75°C、80°C')
    if any(type(x) is not int or not 30 <= x <= 100 for x in speeds):
        raise ValueError('每档转速必须是 30–100 的整数')
    if speeds != sorted(speeds):
        raise ValueError('温度升高时，转速不能降低')
    if len(speeds) == 4:
        speeds = speeds[:3] + [max(speeds[2], min(90, speeds[3]))] + speeds[3:]
    idle_stop = config.get('idle_stop', True)
    if type(idle_stop) is not bool:
        raise ValueError('空闲停转配置必须为开启或关闭状态')
    return {'speeds': speeds, 'idle_stop': idle_stop}


def load_config():
    return validate(json.loads(CONFIG.read_text(encoding='utf-8')))


def save_config(config):
    config = validate(config)
    fd, filename = tempfile.mkstemp(prefix='.curve-', dir=BASE)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            json.dump(config, stream, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(filename, CONFIG)
    finally:
        if os.path.exists(filename):
            os.unlink(filename)


def choose_speed(temp, speeds, previous=None):
    if not 0 <= temp <= 125:
        raise ValueError(f'异常温度读数: {temp}')
    band = sum(temp >= boundary for boundary in THRESHOLDS)
    if previous is not None and band < previous:
        if temp >= THRESHOLDS[previous - 1] - HYSTERESIS:
            band = previous
    return band, (speeds + [100])[band]


def idle_decision(temp, gpu, memory, now, since, active, enabled):
    if not 0 <= temp <= 125 or not 0 <= gpu <= 100 or not 0 <= memory <= 100:
        raise ValueError('温度或负载读数异常')
    if not enabled or gpu != 0 or memory != 0 or temp >= IDLE_EXIT_TEMP:
        return False, None
    if active:
        return True, since
    if temp >= IDLE_ENTER_TEMP:
        return False, None
    since = now if since is None else since
    return now - since >= IDLE_SECONDS, since


@contextlib.contextmanager
def exclusive(name):
    with open('/run/lock/' + name, 'a') as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('已有控制进程正在运行；请从菜单停止温控后再设置固定转速') from None
        yield


class NVML:
    def __init__(self):
        self.lib = C.CDLL('libnvidia-ml.so.1')
        self.lib.nvmlErrorString.restype = C.c_char_p
        self.lib.nvmlErrorString.argtypes = [C.c_int]
        signatures = {
            'nvmlInit_v2': [], 'nvmlShutdown': [],
            'nvmlDeviceGetCount_v2': [C.POINTER(U)],
            'nvmlDeviceGetHandleByIndex_v2': [U, C.POINTER(H)],
            'nvmlDeviceGetNumFans': [H, C.POINTER(U)],
            'nvmlDeviceGetName': [H, C.c_char_p, U],
            'nvmlDeviceGetTemperature': [H, U, C.POINTER(U)],
            'nvmlDeviceGetUtilizationRates': [H, C.POINTER(Utilization)],
            'nvmlDeviceGetMinMaxFanSpeed': [H, C.POINTER(U), C.POINTER(U)],
            'nvmlDeviceGetFanSpeed_v2': [H, U, C.POINTER(U)],
            'nvmlDeviceGetTargetFanSpeed': [H, U, C.POINTER(U)],
            'nvmlDeviceGetFanControlPolicy_v2': [H, U, C.POINTER(U)],
            'nvmlDeviceSetFanSpeed_v2': [H, U, U],
            'nvmlDeviceSetDefaultFanSpeed_v2': [H, U],
        }
        for name, types in signatures.items():
            fn = getattr(self.lib, name)
            fn.argtypes, fn.restype = types, C.c_int
        self.call('nvmlInit_v2')
        self.devices = []
        try:
            for idx in range(self.uint('nvmlDeviceGetCount_v2')):
                h = H()
                self.call('nvmlDeviceGetHandleByIndex_v2', idx, C.byref(h))
                fans = self.uint('nvmlDeviceGetNumFans', h)
                if not fans:
                    raise RuntimeError(f'显卡 {idx} 没有可控制的风扇')
                self.devices.append((idx, h, fans))
            if not self.devices:
                raise RuntimeError('没有找到英伟达显卡')
        except BaseException:
            self.close()
            raise

    def call(self, name, *args):
        rc = getattr(self.lib, name)(*args)
        if rc:
            reasons = {1: '驱动接口尚未初始化', 2: '参数无效', 3: '驱动不支持此操作', 4: '权限不足'}
            reason = reasons.get(rc, '显卡驱动操作失败')
            raise RuntimeError(f'{reason}（驱动错误代码：{rc}）')

    def uint(self, name, *args):
        value = U()
        self.call(name, *args, C.byref(value))
        return value.value

    def select(self, selector='all'):
        if selector in ('all', '全部'):
            return self.devices
        if selector.isascii() and selector.isdecimal():
            selected = [d for d in self.devices if d[0] == int(selector)]
            if selected:
                return selected
        raise ValueError(f'显卡编号无效；请输入“全部”或 0–{len(self.devices) - 1}')

    def speed_limits(self, devices):
        minimum, maximum = 30, 100
        for idx, h, fans in devices:
            lo, hi = U(), U()
            self.call('nvmlDeviceGetMinMaxFanSpeed', h, C.byref(lo), C.byref(hi))
            minimum, maximum = max(minimum, lo.value), min(maximum, hi.value)
        if minimum > maximum:
            raise ValueError('所选显卡没有共同支持的转速范围')
        return minimum, maximum

    def check_speeds(self, devices, speeds):
        minimum, maximum = self.speed_limits(devices)
        if any(not minimum <= speed <= maximum for speed in speeds):
            raise ValueError(f'所选显卡允许的手动转速范围为 {minimum}–{maximum}%；配置未应用')

    def temperature(self, device):
        return self.uint('nvmlDeviceGetTemperature', device[1], 0)

    def utilization(self, device):
        result = Utilization()
        self.call('nvmlDeviceGetUtilizationRates', device[1], C.byref(result))
        return result.gpu, result.memory

    def ensure_auto(self, device):
        _, h, fans = device
        if any(self.uint('nvmlDeviceGetFanControlPolicy_v2', h, fan) != 0 for fan in range(fans)):
            self.restore([device])

    def set_speed(self, device, speed):
        idx, h, fans = device
        for fan in range(fans):
            self.call('nvmlDeviceSetFanSpeed_v2', h, fan, speed)
            target = self.uint('nvmlDeviceGetTargetFanSpeed', h, fan)
            policy = self.uint('nvmlDeviceGetFanControlPolicy_v2', h, fan)
            if target != speed or policy != 1:
                raise RuntimeError(f'显卡 {idx} 风扇 {fan} 设置验证失败')

    def restore(self, devices):
        errors = []
        for idx, h, fans in devices:
            for fan in range(fans):
                try:
                    self.call('nvmlDeviceSetDefaultFanSpeed_v2', h, fan)
                    if self.uint('nvmlDeviceGetFanControlPolicy_v2', h, fan) != 0:
                        raise RuntimeError('自动调速验证失败')
                except Exception as e:
                    errors.append(f'显卡 {idx} 风扇 {fan}：{error_text(e)}')
        if errors:
            raise RuntimeError('\n'.join(errors))

    def show(self, devices):
        for idx, h, fans in devices:
            name = C.create_string_buffer(128)
            self.call('nvmlDeviceGetName', h, name, len(name))
            temp = self.temperature((idx, h, fans))
            gpu, memory = self.utilization((idx, h, fans))
            parts = []
            for fan in range(fans):
                speed = self.uint('nvmlDeviceGetFanSpeed_v2', h, fan)
                target = self.uint('nvmlDeviceGetTargetFanSpeed', h, fan)
                policy = self.uint('nvmlDeviceGetFanControlPolicy_v2', h, fan)
                mode = {0: '原厂自动', 1: '软件控制'}.get(policy, f'未知模式（{policy}）')
                parts.append(f'风扇{fan} {speed}% / 目标{target}% ({mode})')
            model = name.value.decode().replace('NVIDIA GeForce', '英伟达').replace('NVIDIA', '英伟达')
            print(f'显卡 {idx} | {model} | 温度{temp}℃ | 核心负载{gpu}% 显存读写负载{memory}% | ' + ' | '.join(parts))

    def close(self):
        self.lib.nvmlShutdown()


@contextlib.contextmanager
def hardware():
    nv = NVML()
    try:
        yield nv
    finally:
        nv.close()


def notify(message):
    address = os.environ.get('NOTIFY_SOCKET')
    if address:
        if address.startswith('@'):
            address = '\0' + address[1:]
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
            sock.sendto(message.encode(), address)


def control_loop(nv, stop, read_config=load_config, report=notify, clock=time.monotonic):
    previous, applied = {}, {}
    idle_since, idle_active = {}, {}
    last_config = None
    ready = False
    try:
        while not stop.is_set():
            config = read_config()
            if config != last_config:
                nv.check_speeds(nv.devices, config['speeds'] + [100])
                previous.clear()
                idle_since.clear()
                idle_active.clear()
                last_config = config
                print('已加载温控配置: ' + curve_text(config), flush=True)
            for device in nv.devices:
                idx = device[0]
                temp = nv.temperature(device)
                gpu, memory = nv.utilization(device)
                idle, since = idle_decision(temp, gpu, memory, clock(), idle_since.get(idx),
                                            idle_active.get(idx, False), config['idle_stop'])
                idle_since[idx], idle_active[idx] = since, idle
                if idle:
                    nv.ensure_auto(device)
                    if applied.get(idx) != 'idle':
                        print(f'显卡 {idx}：{temp}℃，连续空闲30秒 → 原厂自动（允许停转）', flush=True)
                    applied[idx] = 'idle'
                    previous.pop(idx, None)
                    continue
                band, speed = choose_speed(temp, config['speeds'], previous.get(idx))
                # Reassert and verify every cycle, including if another utility changed it.
                nv.set_speed(device, speed)
                if applied.get(idx) != speed:
                    print(f'显卡 {idx}：{temp}℃ → 转速{speed}%', flush=True)
                    applied[idx] = speed
                previous[idx] = band
            report(('READY=1\n' if not ready else '') + 'WATCHDOG=1\nSTATUS=正在按各卡温度调速')
            ready = True
            stop.wait(INTERVAL)
    finally:
        nv.restore(nv.devices)
        print('全部风扇已恢复原厂自动调速。', flush=True)


def daemon():
    stop = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.set())
    with exclusive('gpu-fan-control.lock'), hardware() as nv:
        control_loop(nv, stop)


def systemctl(*args, check=True):
    return subprocess.run(['systemctl', *args, SERVICE], check=check,
                          text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=40)


def curve_text(config):
    low, s60, s70, s75, s80 = config['speeds']
    curve = f'<60°C: {low}% | 60–69°C: {s60}% | 70–74°C: {s70}% | 75–79°C: {s75}% | 80–84°C: {s80}% | ≥85°C: 100%'
    return curve + ('\n空闲停转: 开启（零负载30秒且低于50°C进入；有负载或达到55°C退出）' if config['idle_stop'] else '\n空闲停转: 关闭')


def service_text():
    state = systemctl('is-active', check=False).stdout.strip()
    state = {'active': '运行中', 'inactive': '已停止', 'failed': '运行异常',
             'activating': '正在启动', 'deactivating': '正在停止',
             'reloading': '正在重新加载', 'refreshing': '正在刷新',
             'maintenance': '正在维护', 'unknown': '尚未安装'}.get(state, '状态暂不可用')
    enabled = systemctl('is-enabled', check=False).stdout.strip() == 'enabled'
    return f'后台温控: {state} | 开机启动: {"是" if enabled else "否"}'


def start_service():
    with exclusive('gpu-fan-admin.lock'):
        config = load_config()
        with hardware() as nv:
            nv.check_speeds(nv.devices, config['speeds'] + [100])
        systemctl('enable', '--now')
    print('温控已启用并设置开机启动；重复启用不会产生多个进程。')


def stop_service():
    with exclusive('gpu-fan-admin.lock'):
        systemctl('disable', '--now')
        with exclusive('gpu-fan-control.lock'), hardware() as nv:
            nv.restore(nv.devices)
    print('温控已停止、开机启动已取消，全部风扇恢复原厂自动调速。')


def configure(speeds):
    with exclusive('gpu-fan-admin.lock'):
        try:
            idle_stop = load_config()['idle_stop']
        except (ValueError, OSError):
            idle_stop = DEFAULT['idle_stop']
        config = validate({'speeds': speeds, 'idle_stop': idle_stop})
        with hardware() as nv:
            nv.check_speeds(nv.devices, speeds + [100])
        save_config(config)
    print('已保存的配置: ' + curve_text(config))
    print('配置已保存。正在运行的温控会在 3 秒内应用；尚未启用时请选择菜单 3。')


def set_idle(enabled=None):
    with exclusive('gpu-fan-admin.lock'):
        config = load_config()
        config['idle_stop'] = not config['idle_stop'] if enabled is None else enabled
        save_config(config)
    print('空闲停转已' + ('开启' if config['idle_stop'] else '关闭') + '，运行中的温控将在3秒内应用。')


def ask_speed(label, default, minimum, maximum, previous=None):
    while True:
        raw = input(f'{label} 的风扇转速 [{default}%]: ').strip()
        try:
            speed = int(raw) if raw else default
        except ValueError:
            print('请输入整数百分比，例如 30（不加 %）；尚未保存，请重新输入。')
            continue
        if not minimum <= speed <= maximum:
            print(f'未接受 {speed}%：本机允许 {minimum}–{maximum}%，最低 {minimum}%。'
                  '尚未保存，当前配置不变，请重新输入。')
            continue
        if previous is not None and speed < previous:
            print(f'高温档不能低于上一档 {previous}%。尚未保存，请重新输入。')
            continue
        return speed


def menu():
    if not sys.stdin.isatty():
        raise RuntimeError('交互菜单需要终端；请远程登录后输入“fan”，或输入“fan 帮助”查看其他用法')
    while True:
        print('\n========== 显卡风扇温控 ==========')
        print(service_text())
        try:
            print(curve_text(load_config()))
        except (ValueError, OSError) as e:
            print(f'配置错误：{error_text(e)}；请选择 2 重新设置')
        print('每张卡独立按自身温度调速；降温回差 3°C；每 3 秒检查一次。')
        print('\n1. 查看显卡温度和风扇状态\n2. 设置并保存各温度档转速\n3. 启用温控（含开机启动）\n4. 停止温控，恢复原厂自动\n5. 查看最近日志\n6. 开启/关闭空闲停转\n0. 退出菜单（保持现有运行状态）')
        try:
            choice = input('请选择 [0–6]: ').strip()
            if choice == '0':
                return
            if choice == '1':
                with hardware() as nv:
                    nv.show(nv.devices)
            elif choice == '2':
                try:
                    current = load_config()['speeds']
                except (ValueError, OSError):
                    current = DEFAULT['speeds']
                with hardware() as nv:
                    minimum, maximum = nv.speed_limits(nv.devices)
                print(f'本机手动转速范围：{minimum}–{maximum}%。请输入整数，回车保留当前值；Ctrl+C 取消。')
                print('五档全部输入有效后才保存；输入无效会留在当前档重新输入。')
                speeds = []
                for label, default in zip(['低于60°C', '60°C起', '70°C起', '75°C起', '80°C起'], current):
                    speeds.append(ask_speed(label, default, minimum, maximum,
                                            speeds[-1] if speeds else None))
                configure(speeds)
            elif choice == '3':
                start_service()
            elif choice == '4':
                stop_service()
            elif choice == '5':
                show_logs()
            elif choice == '6':
                set_idle()
            else:
                print('请输入 0–6。')
        except EOFError:
            return
        except KeyboardInterrupt:
            print('\n已取消本次输入；现有温控状态不变。')
        except Exception as e:
            print('操作失败: ' + error_text(e))


def show_logs():
    result = subprocess.run(['journalctl', '-u', SERVICE, '-n', '150', '--no-pager', '-o', 'json'],
                            capture_output=True, text=True, check=True, timeout=15)
    lines = []
    for raw in result.stdout.splitlines():
        entry = json.loads(raw)
        if entry.get('_COMM') == 'systemd' or entry.get('SYSLOG_IDENTIFIER') == 'systemd':
            continue
        message = entry.get('MESSAGE', '')
        if not isinstance(message, str):
            continue
        message = message.replace('GPU', '显卡').replace('°C', '℃').replace('->', '→')
        if 'nvml' in message:
            message = '显卡驱动接口报告异常，请检查驱动和设备状态。'
        stamp = int(entry.get('__REALTIME_TIMESTAMP', '0')) / 1000000
        lines.append(time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(stamp)) + '  ' + message)
    print('最近的温控程序日志：')
    print('\n'.join(lines[-25:]) if lines else '暂无程序日志。')


def error_text(error):
    if isinstance(error, json.JSONDecodeError):
        return f'配置内容格式不正确（第{error.lineno}行，第{error.colno}列），请重新设置'
    if isinstance(error, subprocess.CalledProcessError):
        return f'系统服务或日志操作失败（退出代码：{error.returncode}），请检查服务状态及管理员权限'
    if isinstance(error, subprocess.TimeoutExpired):
        return '操作等待超时，请稍后查看服务状态'
    if isinstance(error, PermissionError):
        return '权限不足，请以管理员身份运行'
    if isinstance(error, FileNotFoundError):
        return '所需文件或系统命令不存在，请检查安装是否完整'
    if isinstance(error, OSError):
        return f'无法访问所需的文件、驱动库或系统资源（系统错误代码：{error.errno}）'
    return str(error)


def main():
    argv = sys.argv[1:]
    if any(arg in ('帮助', '-h', '--help') for arg in argv):
        print(HELP_TEXT)
        return
    aliases = {'菜单': 'menu', '状态': 'status', '配置': 'configure', '空闲': 'idle',
               '启动': 'start', '停止': 'stop', '自动': 'auto', '固定': 'set', '日志': 'logs'}
    if argv:
        argv[0] = aliases.get(argv[0], argv[0])
    argv = [{'全部': 'all', '开启': 'on', '关闭': 'off'}.get(arg, arg) for arg in argv]
    parser = ChineseParser(prog='fan', description='交互式显卡风扇温控；不带参数打开菜单', add_help=False)
    subs = parser.add_subparsers(dest='command')
    for cmd in ['menu', 'start', 'stop', 'daemon', '_restore', 'logs']:
        subs.add_parser(cmd)
    for cmd in ['status', 'set', 'auto']:
        sub = subs.add_parser(cmd)
        if cmd == 'set':
            sub.add_argument('percent', type=int)
        sub.add_argument('gpu', nargs='?', default='all')
    sub = subs.add_parser('configure', help='保存低温、60°C、70°C、75°C、80°C对应百分比')
    sub.add_argument('speeds', type=int, nargs=5)
    sub = subs.add_parser('idle', help='开启或关闭空闲停转')
    sub.add_argument('mode', choices=['on', 'off'])
    args = parser.parse_args(argv)
    if os.geteuid() != 0:
        raise RuntimeError('请以管理员身份运行')
    cmd = args.command or 'menu'
    if cmd == 'menu':
        menu()
    elif cmd == 'daemon':
        daemon()
    elif cmd == 'configure':
        configure(args.speeds)
    elif cmd == 'idle':
        set_idle(args.mode == 'on')
    elif cmd == 'logs':
        show_logs()
    elif cmd == 'start':
        start_service()
    elif cmd == 'stop' or (cmd == 'auto' and args.gpu == 'all'):
        stop_service()
    elif cmd == 'status':
        print(service_text())
        print(curve_text(load_config()))
        with hardware() as nv:
            nv.show(nv.select(args.gpu))
    else:
        with exclusive('gpu-fan-control.lock'), hardware() as nv:
            devices = nv.select(getattr(args, 'gpu', 'all'))
            if cmd in ['auto', '_restore']:
                nv.restore(devices)
            elif cmd == 'set':
                if not 30 <= args.percent <= 100:
                    raise ValueError('转速必须在 30–100 之间')
                nv.check_speeds(devices, [args.percent])
                try:
                    for device in devices:
                        nv.set_speed(device, args.percent)
                except BaseException:
                    nv.restore(devices)
                    raise
                print('已设置固定转速；输入“fan 自动”恢复原厂自动调速。')
            nv.show(devices)


if __name__ == '__main__':
    try:
        main()
    except (Exception, KeyboardInterrupt) as e:
        print('错误: ' + (error_text(e) or '操作中断'), file=sys.stderr)
        sys.exit(1)
FAN_EMBEDDED_PAYLOAD_2_END

cat > "$bundle_dir/fan" <<'FAN_EMBEDDED_PAYLOAD_3_END'
#!/usr/bin/env bash
exec /root/gpu-fan-control/fan-control.sh "$@"
FAN_EMBEDDED_PAYLOAD_3_END

cat > "$bundle_dir/gpu-fan-control.service" <<'FAN_EMBEDDED_PAYLOAD_4_END'
[Unit]
Description=NVIDIA GPU temperature-based fan control
After=nvidia-persistenced.service
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=notify
NotifyAccess=main
User=root
WorkingDirectory=/root/gpu-fan-control
ExecStart=/usr/bin/python3 -u /root/gpu-fan-control/fan_control.py daemon
ExecStopPost=/usr/bin/python3 -u /root/gpu-fan-control/fan_control.py _restore
Restart=on-failure
RestartSec=5
WatchdogSec=20
TimeoutStartSec=20
TimeoutStopSec=15
Environment=PYTHONIOENCODING=utf-8
UMask=0077

[Install]
WantedBy=multi-user.target
FAN_EMBEDDED_PAYLOAD_4_END

cat > "$bundle_dir/curve.example.json" <<'FAN_EMBEDDED_PAYLOAD_5_END'
{
  "speeds": [40, 60, 80, 90, 100],
  "idle_stop": true
}
FAN_EMBEDDED_PAYLOAD_5_END

cat > "$bundle_dir/README.md" <<'FAN_EMBEDDED_PAYLOAD_6_END'
# 英伟达显卡风扇温控

中文终端菜单，支持多卡独立温控、低温空闲停转和开机自启。安装后输入 `fan` 即可操作。

基于显卡驱动自带的 NVML 接口，只使用 Python 标准库，不需要安装 Python 第三方依赖、桌面环境或配置 Coolbits。

## 环境要求

- 使用 systemd 的 Linux 系统、Bash、Python 3 和管理员权限。
- 已安装正常工作的英伟达驱动，并提供 `libnvidia-ml.so.1`。
- 显卡及驱动必须支持风扇读写接口和负载查询接口。

已在 Ubuntu 22.04、驱动 580.178.04、八张 RTX 5090 上验证。其他显卡需要自行确认驱动支持；没有风扇控制接口的设备无法使用。此项目控制的是显卡风扇，不控制机箱或服务器主板风扇。

## 安装

下载或克隆本项目，在项目目录运行：

```bash
sudo bash install.sh --check  # 可选：只检查环境和配置
sudo bash install.sh
sudo fan
```

以管理员账户登录时可直接输入 `fan`。脚本安装到 `/root/gpu-fan-control`，快捷命令安装到 `/usr/local/bin/fan`。

第一次安装不会立即接管风扇。打开菜单，选 **2** 设置温度曲线，再选 **3** 启用后台温控和开机自启。

重复安装会保留配置和开机启动设置；如果服务原本正在运行，升级时会短暂停止并恢复。升级备份保存在安装目录的 `.backups` 中。环境检查只读取接口；首次实际写入风扇目标仍可能受设备固件限制，失败会报错并尝试恢复原厂自动调速。

## 交互菜单

```text
1. 查看显卡温度和风扇状态
2. 设置并保存各温度档转速
3. 启用温控（含开机启动）
4. 停止温控，恢复原厂自动
5. 查看最近日志
6. 开启/关闭空闲停转
0. 退出菜单（保持现有运行状态）
```

退出菜单、断开远程连接后，已启用的后台温控继续运行。重复打开菜单或启用服务不会创建多个控制进程。

## 默认温度曲线

每张卡根据自身温度独立调速，所有卡使用同一份曲线。

| 温度区间 | 风扇目标 |
| --- | ---: |
| 低于 60℃，未满足空闲停转条件 | 40% |
| 60–69℃ | 60% |
| 70–74℃ | 80% |
| 75–79℃ | 90% |
| 80℃及以上 | 100% |

每 3 秒采样一次。升温达到阈值时升档；降温低于当前档位阈值减 3℃ 后才降档，避免频繁切换。例如从 75℃ 档降温时，低于 72℃ 才允许降档。

菜单可修改五档转速，85℃ 起额外强制 100%。手动范围为 30%–100%，同时遵守各卡驱动返回的有效范围。输入无效会立即提示并要求重输，五档全部有效才保存。

## 空闲停转

默认开启，逐卡判断：

1. 核心负载和显存读写负载连续 30 秒的采样均为 0%，且温度低于 50℃，切回原厂自动调速，允许固件停转。
2. 检测到任一负载大于 0%，或温度达到 55℃，在下一次采样时恢复软件温控。

这里的显存读写负载是活动百分比，不是显存占用容量。高温刚结束任务时不会因负载归零而立即停转。

空闲停转依赖显卡固件，并非强制设置 0%；原厂策略仍可以自行启动风扇。短暂负载脉冲可能发生在两次采样之间。已验证的 RTX 5090 在低温空闲时，各风扇均可报告 0%。百分比来自驱动报告，并非独立测量的物理转速。

## 命令行

```bash
fan                         # 交互菜单
fan 状态                    # 查看全部显卡
fan 状态 0                  # 查看显卡零
fan 配置 40 60 80 90 100     # 低温、六十、七十、七十五、八十度档
fan 空闲 开启
fan 空闲 关闭
fan 启动                    # 启动并设置开机自启
fan 停止                    # 停止、取消开机自启、恢复原厂自动
fan 自动                    # 等同于停止命令
fan 日志
fan 帮助
```

停止后台后，可用 `fan 固定 60 0` 将显卡零固定为 60%，用 `fan 自动 0` 恢复该卡原厂自动。固定转速不会随温度升高而提高。后台运行时拒绝单次手动控制，避免互相覆盖。

原英文命令兼容：`status`、`configure`、`idle on/off`、`start`、`stop`、`auto`、`set`、`logs`、`--help`。

## 配置和服务

默认配置由 `curve.example.json` 提供。运行时配置为 `/root/gpu-fan-control/curve.json`，菜单原子保存，后台在下一次采样时读取。运行时配置已加入忽略列表，避免提交个人设置。

服务名为 `gpu-fan-control.service`。异常退出时尝试恢复所有风扇为原厂自动，并由系统尝试重启服务。若驱动或设备已无法响应，恢复操作也可能失败。

```bash
sudo systemctl status gpu-fan-control.service
sudo journalctl -u gpu-fan-control.service -n 50 --no-pager
```

卸载前，先执行 `sudo fan 停止`。本项目未提供自动删除目录的命令，配置与备份可按需保留。

## 项目文件

```text
fan-control.sh              脚本入口
fan_control.py              中文菜单和温控实现
fan                         全局快捷命令
install.sh                  安装和环境检查
gpu-fan-control.service     后台服务定义
curve.example.json          默认配置
tests/test_fan_control.py   温控逻辑与输入校验测试
```

`fan-control.sh` 依赖同目录的 `fan_control.py`，请保留完整项目，不要只复制一个入口文件。

## 验证

在 Linux 项目目录运行下列命令。单元测试使用模拟设备，不会修改真实显卡的风扇。

```bash
sudo python3 -B -m unittest discover -s tests -v
bash -n install.sh fan-control.sh fan
```

涵盖温度分档、降温回差、配置迁移、输入校验、空闲计时、负载恢复、多卡独立控制及失败后的恢复行为。

## 上传 GitHub

将本目录内的全部项目文件上传到仓库根目录，包括 `.gitignore` 和 `.gitattributes`。发行包不含私钥、服务器地址、登录信息或机器日志。

项目尚未指定开源许可证；如需授权他人使用、修改或分发，请在发布时选择许可证并添加 `LICENSE` 文件。

接口依据：[英伟达风扇控制文档](https://docs.nvidia.com/deploy/nvml-api/api/group__nvmlDeviceCommands.html)。
FAN_EMBEDDED_PAYLOAD_6_END

cat > "$bundle_dir/install.sh" <<'FAN_EMBEDDED_PAYLOAD_7_END'
#!/usr/bin/env bash
# 安装到固定目录；重复安装保留已保存的配置和开机启动设置。
set -euo pipefail
export PYTHONIOENCODING=utf-8
SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR=/root/gpu-fan-control
COMMAND_PATH=/usr/local/bin/fan
UNIT_PATH=/etc/systemd/system/gpu-fan-control.service
SERVICE=gpu-fan-control.service

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    echo '用法：sudo bash install.sh [--check]'
    echo '不带参数安装；--check 只检查依赖、驱动接口和现有配置。'
    exit 0
fi
if [[ $# -gt 1 || ( $# -eq 1 && $1 != --check ) ]]; then
    echo '参数不正确，请使用 --help 查看帮助。' >&2
    exit 1
fi
if [[ $EUID -ne 0 ]]; then
    echo '请以管理员身份运行：sudo bash install.sh' >&2
    exit 1
fi
for tool in python3 systemctl install flock mktemp cp cmp mv; do
    command -v "$tool" >/dev/null || { echo "缺少系统命令：$tool" >&2; exit 1; }
done
[[ -d /run/systemd/system ]] || { echo '此安装方式需要正在运行的系统服务管理器。' >&2; exit 1; }
for file in fan-control.sh fan_control.py fan gpu-fan-control.service curve.example.json README.md; do
    [[ -f "$SOURCE_DIR/$file" ]] || { echo "安装文件缺失：$file" >&2; exit 1; }
done

# 和菜单中的配置操作互斥；后台温控使用独立的硬件控制锁。
exec 9>/run/lock/gpu-fan-admin.lock
flock -n 9 || { echo '另一个配置或安装操作正在进行，请稍后重试。' >&2; exit 1; }
python3 -B - "$SOURCE_DIR" "$TARGET_DIR" <<'PY'
import json
from pathlib import Path
import sys
sys.path.insert(0, sys.argv[1])
import fan_control as f
try:
    config_path = Path(sys.argv[2]) / 'curve.json'
    if not config_path.exists():
        config_path = Path(sys.argv[1]) / 'curve.example.json'
    config = f.validate(json.loads(config_path.read_text(encoding='utf-8')))
    with f.hardware() as nv:
        nv.check_speeds(nv.devices, config['speeds'] + [100])
        for device in nv.devices:
            nv.temperature(device)
            nv.utilization(device)
        print(f'环境检查通过：识别到 {len(nv.devices)} 张显卡，现有配置有效。')
except Exception as exc:
    sys.exit('环境检查失败：' + f.error_text(exc))
PY
[[ ${1:-} != --check ]] || exit 0

for path in "$TARGET_DIR" "$COMMAND_PATH" "$UNIT_PATH"; do
    [[ ! -L "$path" ]] || { echo "目标是符号链接，请先手动检查：$path" >&2; exit 1; }
done
if [[ -e "$COMMAND_PATH" ]] && ! cmp -s "$SOURCE_DIR/fan" "$COMMAND_PATH"; then
    echo '已有其他 fan 命令，安装已停止，原命令未覆盖。' >&2
    exit 1
fi
if [[ -d "$TARGET_DIR" && ! -f "$TARGET_DIR/fan_control.py" ]]; then
    echo '目标目录已存在，但不是本程序的安装目录，请先手动检查。' >&2
    exit 1
fi
install -d -m 700 "$TARGET_DIR" "$TARGET_DIR/.backups"
backup="$(mktemp -d "$TARGET_DIR/.backups/install-XXXXXXXX")"
paths=("$TARGET_DIR/fan_control.py" "$TARGET_DIR/fan-control.sh" "$TARGET_DIR/README.md" "$TARGET_DIR/curve.json" "$COMMAND_PATH" "$UNIT_PATH")
for i in "${!paths[@]}"; do
    if [[ -e ${paths[$i]} ]]; then
        [[ ! -L ${paths[$i]} ]] || { echo "目标文件是符号链接：${paths[$i]}" >&2; exit 1; }
        cp -p -- "${paths[$i]}" "$backup/$i"
    fi
done
was_active=false
if systemctl is-active --quiet "$SERVICE"; then was_active=true; fi
rollback() {
    trap - ERR
    set +e
    systemctl stop "$SERVICE" >/dev/null 2>&1
    for i in "${!paths[@]}"; do
        if [[ -f "$backup/$i" ]]; then
            cp -p -- "$backup/$i" "${paths[$i]}"
        else
            rm -f -- "${paths[$i]}"
        fi
    done
    systemctl daemon-reload
    if "$was_active"; then systemctl start "$SERVICE"; fi
    echo "安装失败，已尝试恢复原文件；备份位置：$backup" >&2
    exit 1
}
trap rollback ERR
if "$was_active"; then systemctl stop "$SERVICE"; fi
install -m 600 "$SOURCE_DIR/fan_control.py" "$TARGET_DIR/fan_control.py"
install -m 700 "$SOURCE_DIR/fan-control.sh" "$TARGET_DIR/fan-control.sh"
install -m 600 "$SOURCE_DIR/README.md" "$TARGET_DIR/README.md"
if [[ ! -f "$TARGET_DIR/curve.json" ]]; then
    install -m 600 "$SOURCE_DIR/curve.example.json" "$TARGET_DIR/curve.json"
fi
install -m 755 "$SOURCE_DIR/fan" "$COMMAND_PATH"
install -m 644 "$SOURCE_DIR/gpu-fan-control.service" "$UNIT_PATH"
systemctl daemon-reload
if "$was_active"; then systemctl start "$SERVICE"; fi
trap - ERR
echo '安装完成。输入 fan 打开中文交互菜单。'
echo '首次安装：菜单 2 设置曲线，菜单 3 启用温控和开机启动。'
echo '重复安装：保留现有配置；原本运行中的温控已恢复运行。'
FAN_EMBEDDED_PAYLOAD_7_END

if [[ ${1:-} == --check ]]; then
    bash "$bundle_dir/install.sh" --check
    exit 0
fi

# 配置属于用户，不纳入版本比较，也不被默认值覆盖。
same_version=true
sources=(fan-control.sh fan_control.py fan gpu-fan-control.service README.md)
targets=(/root/gpu-fan-control/fan-control.sh /root/gpu-fan-control/fan_control.py \
    /usr/local/bin/fan /etc/systemd/system/gpu-fan-control.service /root/gpu-fan-control/README.md)
for i in "${!sources[@]}"; do
    if [[ -L ${targets[$i]} ]] || ! cmp -s "$bundle_dir/${sources[$i]}" "${targets[$i]}"; then
        same_version=false
        break
    fi
done
if [[ ! -f /root/gpu-fan-control/curve.json || ! -x /usr/local/bin/fan || ! -x /root/gpu-fan-control/fan-control.sh ]]; then
    same_version=false
fi
if "$same_version"; then
    echo '已安装相同版本，现有配置和后台进程保持不变。'
else
    bash "$bundle_dir/install.sh"
fi

cleanup
trap - EXIT
if [[ $# -eq 0 && -t 0 && -t 1 ]]; then
    exec /usr/local/bin/fan
fi
echo '准备就绪。输入 fan 打开中文交互菜单。'
