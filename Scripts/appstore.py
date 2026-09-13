#!/usr/bin/env python3
"""项目发布入口；配置统一读取 appstoreConfig/config.json。"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import plistlib
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CONFIG_DIR = ROOT / 'appstoreConfig'


def require(ok, message):
    if not ok:
        raise ValueError(message)


def run(*args, env=None, capture=False):
    result = subprocess.run(args, cwd=ROOT, env=env, check=True,
                            stdout=subprocess.PIPE if capture else None, text=True)
    return result.stdout.strip() if capture else None


def load_config():
    file = CONFIG_DIR / 'config.json'
    require(file.is_file(), '缺少 appstoreConfig/config.json，请恢复本机发布配置备份。')
    config = json.loads(file.read_text())
    for name in ('key_id', 'issuer_id', 'private_key', 'ruby_bin', 'developer_dir',
                 'release_root', 'project', 'scheme', 'bundle_id', 'export_options', 'locale', 'initial_base', 'source_paths'):
        require(bool(config.get(name)), f'appstoreConfig/config.json 缺少 {name}')
    key = (CONFIG_DIR / config['private_key']).resolve()
    require(key.parent == CONFIG_DIR.resolve() and key.is_file(), '私钥必须位于 appstoreConfig 内且文件存在。')
    # gitignore 不会自动取消已跟踪文件；两种情况分别检查。
    tracked = run('git', 'ls-files', '--', 'appstoreConfig', capture=True)
    require(not tracked, 'appstoreConfig 有文件被 Git 跟踪，请先移出 Git 索引。')
    run('git', 'check-ignore', '-q', '--', str(file))
    run('git', 'check-ignore', '-q', '--', str(key))
    CONFIG_DIR.chmod(0o700)
    file.chmod(0o600)
    key.chmod(0o600)
    env = os.environ.copy()
    if config.get('direct_connection', True):
        for name in ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy'):
            env.pop(name, None)
    env.update(
        PATH=config['ruby_bin'] + os.pathsep + env.get('PATH', ''),
        ASC_KEY_ID=config['key_id'], ASC_ISSUER_ID=config['issuer_id'], ASC_KEY_FILE=str(key),
        DEVELOPER_DIR=config['developer_dir'], TIMETRACE_RELEASE_ROOT=config['release_root'],
        RELEASE_PROJECT=config['project'], RELEASE_SCHEME=config['scheme'],
        RELEASE_BUNDLE_ID=config['bundle_id'], RELEASE_EXPORT_OPTIONS=config['export_options'],
        RELEASE_LOCALE=config['locale'], FASTLANE_SKIP_UPDATE_CHECK='1',
        FASTLANE_OPT_OUT_USAGE='1', FASTLANE_DISABLE_COLORS='1', PYTHONDONTWRITEBYTECODE='1'
    )
    require(Path(config['ruby_bin'], 'ruby').is_file(), '配置中的 Ruby 不存在。')
    require(Path(config['developer_dir'], 'usr/bin/xcodebuild').is_file(), '配置中的完整 Xcode 不存在。')
    config['release_root'] = str(Path(config['release_root']).expanduser().resolve())
    return config, env


def inspect_project(config, env):
    settings = json.loads(run('xcodebuild', '-project', str(ROOT / config['project']),
        '-scheme', config['scheme'], '-configuration', 'Release', '-destination', 'generic/platform=iOS', '-showBuildSettings', '-json', env=env, capture=True))
    apps = [item['buildSettings'] for item in settings
            if item['buildSettings'].get('FULL_PRODUCT_NAME', '').endswith('.app')]
    require(len(apps) == 1, 'Scheme 未唯一对应一个主应用，请检查配置。')
    actual = apps[0]['PRODUCT_BUNDLE_IDENTIFIER']
    require(config['bundle_id'] == 'auto' or config['bundle_id'] == actual,
            f'配置 Bundle ID 与项目不一致：项目实际为 {actual}，已停止。')
    config['bundle_id'] = actual
    env['RELEASE_BUNDLE_ID'] = actual
    env['TIMETRACE_RELEASE_ROOT'] = str(Path(config['release_root']) / actual)
    return apps[0]['MARKETING_VERSION']


def commit_state(states, commit):
    matches = [s for s in states if s.get('head') == commit]
    return max(matches, key=lambda s: (bool(s.get('submitted')), bool(s.get('metadata_sha256')),
        bool(s.get('uploaded')), bool(s.get('ipa')), bool(s.get('archive_complete')),
        s['_path'].stat().st_mtime), default=None)


def dependency_check(env, install=True):
    require(shutil.which('bundle', path=env['PATH']), '配置的 Ruby 环境缺少 Bundler。')
    result = subprocess.run(['bundle', 'check'], cwd=ROOT, env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode:
        require(install, '发布依赖尚未安装；直接执行 ./appstore.sh 会自动安装。')
        print('正在安装项目发布依赖……', flush=True)
        run('bundle', 'config', 'set', '--local', 'path', 'build/bundle', env=env)
        run('bundle', 'install', env=env)


def release_states(root, bundle_id):
    states = []
    # 兼容首次上传的旧目录；必须从 IPA 核实 Bundle ID，不能跨项目复用。
    paths = list((root / bundle_id).glob('*/attempt-*/state.json')) + list(root.glob('*/attempt-*/state.json'))
    for path in paths:
        state = json.loads(path.read_text())
        identity = state.get('bundle_id')
        if not identity and state.get('ipa') and Path(state['ipa']).is_file():
            with zipfile.ZipFile(state['ipa']) as ipa:
                import re
                names = [n for n in ipa.namelist() if re.fullmatch(r'Payload/[^/]+\.app/Info.plist', n)]
                if len(names) == 1:
                    identity = plistlib.loads(ipa.read(names[0])).get('CFBundleIdentifier')
        if identity != bundle_id:
            continue
        state.update(bundle_id=identity, _path=path, _attempt=int(path.parent.name.split('-')[1]))
        states.append(state)
    return sorted(states, key=lambda s: s['_path'].stat().st_mtime)


def step(name, state, env, *extra):
    print(f'\n▶ {name}：{state["version"]} / 第 {state["_attempt"]} 次构建', flush=True)
    run(sys.executable, str(ROOT / 'Scripts/release.py'), name, '--version', state['version'],
        '--attempt', str(state['_attempt']), *extra,
        env=dict(env, TIMETRACE_RELEASE_ROOT=str(state['_path'].parents[2])))
    updated = json.loads(state['_path'].read_text())
    state.update(updated)


def confirm_notes(state):
    notes = state['_path'].parent / 'release-notes.txt'
    while True:
        print(f'\n更新说明：\n{notes.read_text().strip() or "（尚无说明，请选择 e 编辑）"}\n')
        choice = input('回车确认；e 编辑；q 退出：').strip().lower()
        if choice == 'q':
            raise KeyboardInterrupt
        if choice == 'e':
            run('open', '-e', str(notes))
            input('请保存文案后回车继续：')
            continue
        require(choice == '', '输入无效，已停止。')
        content = notes.read_text().strip()
        require(content and len(content.encode('utf-8')) <= 4000, '说明为空或超过 4000 UTF-8 字节，请编辑后继续。')
        return


def new_release(config, env, previous, current_version):
    with tempfile.TemporaryDirectory(prefix='timetrace-version-') as temporary:
        result = Path(temporary) / 'version.json'
        check_env = dict(env, RELEASE_CANDIDATE=current_version, RELEASE_VERSION_RESULT=str(result))
        run('bundle', 'exec', 'fastlane', 'ios', 'release_resolve', env=check_env)
        version = json.loads(result.read_text())['version']
    root = Path(env['TIMETRACE_RELEASE_ROOT'])
    attempts = [int(p.name.split('-')[1]) for p in (root / version).glob('attempt-*') if p.name.split('-')[1].isdigit()]
    attempt = max(attempts, default=0) + 1
    uploaded = [s for s in previous if s.get('uploaded')]
    base = uploaded[-1]['head'] if uploaded else config['initial_base']
    # 固定刚解析的版本，避免 notes 的第二次网络检查悄悄改变目录。
    run(sys.executable, str(ROOT / 'Scripts/release.py'), 'notes', '--version', version,
        '--attempt', str(attempt), '--base', base, '--fixed-version', env=env)
    file = root / version / f'attempt-{attempt}' / 'state.json'
    require(file.exists(), 'Apple 版本状态在准备期间变化，请重新运行。')
    state = json.loads(file.read_text())
    state.update(_path=file, _attempt=attempt)
    return state


def upload(state, env):
    if state.get('uploaded'):
        print('此构建已上传并处理完成，不重复上传。')
        return
    confirm_notes(state)
    if not state.get('ipa'):
        step('archive', state, env)
    marker = state['_path'].parent / 'upload-started'
    extra = []
    if marker.exists():
        remote = remote_status(state, env)
        require(remote['exists'], 'Apple 尚未显示该构建，上传结果仍不明确。保留进度，请稍后重试；不会自动重传。')
        require(remote['processing'] not in ('INVALID', 'FAILED'), 'Apple 判定构建无效，请修复后创建新构建。')
        extra.append('--adopt-upload')
    marker.touch()
    step('upload', state, env, '--notes-reviewed', *extra)
    print(f'\nTestFlight 上传完成：{state["version"]}（{state["build"]}）')


def remote_status(state, env):
    run('bundle', 'exec', 'fastlane', 'ios', 'release_remote_status',
        env=dict(env, RELEASE_DIR=str(state['_path'].parent)))
    return json.loads((state['_path'].parent / 'remote-status.json').read_text())


def persist(state):
    data = {k: v for k, v in state.items() if not k.startswith('_')}
    temporary = state['_path'].with_suffix('.tmp')
    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(state['_path'])


RELEASE_MODES = {'automatic': '审核通过后自动发布', 'manual': '审核通过后手动发布'}


def choose_release_mode(state):
    previous = state.get('release_mode')
    print('\n请选择发布方式：\n1. 审核通过后自动发布\n2. 审核通过后手动发布')
    suffix = f'（回车沿用：{RELEASE_MODES[previous]}）' if previous in RELEASE_MODES else ''
    while True:
        answer = input(f'选择 1 或 2{suffix}：').strip()
        mode = {'1': 'automatic', '2': 'manual'}.get(answer)
        if not answer and previous in RELEASE_MODES:
            mode = previous
        if mode:
            state['release_mode'] = mode
            persist(state)
            return RELEASE_MODES[mode]
        print('请明确选择 1 或 2。')


def review(state, env):
    require(state.get('uploaded'), '此构建尚未上传成功。')
    if state.get('submitted'):
        print('审核已提交，跳过。')
        return
    if state.get('submit_started'):
        if remote_status(state, env)['submitted']:
            state['submitted'] = True
            persist(state)
            print('Apple 已确认此构建已提交审核，已补齐本地记录。')
            return
    print('请将说明核对为面向用户的版本更新内容，并确认 Apple 后台审核资料已完整。')
    confirm_notes(state)
    release_label = choose_release_mode(state)
    if input(f'将 {state["version"]}（{state["build"]}）提交审核，{release_label}。确认请输入 submit：').strip() != 'submit':
        print('已保留上传结果，未提交审核。')
        return
    digest = hashlib.sha256((state['_path'].parent / 'release-notes.txt').read_bytes()).hexdigest()
    if state.get('metadata_sha256') != digest or state.get('metadata_release_mode') != state['release_mode']:
        step('metadata', state, env, '--notes-reviewed')
    else:
        print('更新说明及发布方式均已填写，跳过。')
    state['submit_started'] = True
    persist(state)
    step('submit', state, env)
    print(f'已提交审核；{release_label}。')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='只验证本机配置和依赖，不连接 Apple、不上传')
    args = parser.parse_args()
    config, env = load_config()
    with (CONFIG_DIR / '.run.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        dependency_check(env, install=not args.check)
        if args.check:
            inspect_project(config, env)
            print('配置、私钥权限、Git 忽略规则、Ruby、Xcode 和发布依赖检查通过。')
            return
        require(sys.stdin.isatty(), '请在终端直接执行 ./appstore.sh；自动检查使用 --check。')
        version = inspect_project(config, env)
        commit = run('git', 'rev-parse', 'HEAD', capture=True)
        dirty = run('git', 'status', '--porcelain', '--untracked-files=all', '--', *config['source_paths'], capture=True)
        require(not dirty, '应用源码存在未提交改动。请先提交，脚本按 commit 区分构建。')
        env.update(RELEASE_COMMIT_ID=commit, RELEASE_SOURCE_PATHS=json.dumps(config['source_paths']))
        states = release_states(Path(config['release_root']), config['bundle_id'])
        state = commit_state(states, commit)
        print(f'\n当前 App：{config["bundle_id"]}\n当前 commit：{commit[:12]}')
        if state:
            print(f'复用版本 {state["version"]} / 构建 {state.get("build", "尚未完成归档")}')
        print('1. 继续当前 commit 到 TestFlight（已完成步骤自动跳过）\n2. 继续当前 commit 到 App Store 审核\n3. 查看当前 commit 进度')
        action = input('选择（回车选 1）：').strip() or '1'
        if action == '3':
            print('尚无发布记录。' if not state else
                  f'归档：{bool(state.get("archive_complete") or state.get("ipa"))}，上传：{bool(state.get("uploaded"))}，资料：{bool(state.get("metadata_sha256"))}，提审：{bool(state.get("submitted"))}')
            return
        require(action in ('1', '2'), '输入无效，已退出。')
        if state is None:
            state = new_release(config, env, states, version)
        upload(state, env)
        if action == '2':
            review(state, env)



if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('\n已停止；已有发布进度保留。')
        sys.exit(130)
    except (ValueError, OSError, subprocess.CalledProcessError, KeyError) as error:
        print(f'发布停止：{error}', file=sys.stderr)
        sys.exit(1)
