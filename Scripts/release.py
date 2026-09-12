#!/usr/bin/env python3
"""时光落点分阶段发布入口；所有远端操作都必须显式执行对应子命令。"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = os.environ.get('RELEASE_BUNDLE_ID', 'com.chronora.time.trace')


def run(*args, capture=False, env=None):
    result = subprocess.run(args, cwd=ROOT, env=env, check=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.decode('utf-8').strip() if capture else None


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def snapshot():
    # 包含未提交及未跟踪源码；忽略构建产物、密钥等 gitignored 文件。
    names = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others',
                                     '--exclude-standard'], cwd=ROOT).split(b'\0')
    h = hashlib.sha256()
    for raw in sorted(set(names) - {b''}):
        path = ROOT / os.fsdecode(raw)
        h.update(raw + b'\0')
        h.update(digest(path).encode() if path.is_file() else b'DELETED')
    return h.hexdigest()


def require(ok, message):
    if not ok:
        raise ValueError(message)


def source_matches(state):
    if os.environ.get('RELEASE_COMMIT_ID'):
        paths = json.loads(os.environ['RELEASE_SOURCE_PATHS'])
        return (state.get('head') == os.environ['RELEASE_COMMIT_ID'] == run('git', 'rev-parse', 'HEAD', capture=True)
                and not run('git', 'status', '--porcelain', '--untracked-files=all', '--', *paths, capture=True))
    return state.get('source') == snapshot()


def call_fastlane(lane, **extra):
    key = os.environ.get('ASC_KEY_FILE', '')
    require(key and Path(key).expanduser().is_file(), '缺少私钥配置，请通过项目根目录的 ./appstore.sh 执行')
    require(os.environ.get('ASC_KEY_ID') and os.environ.get('ASC_ISSUER_ID'),
            '设置 ASC_KEY_ID 和 ASC_ISSUER_ID（团队 App Store Connect API Key）')
    env = os.environ.copy()
    env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    env.update(ASC_KEY_FILE=str(Path(key).expanduser().resolve()),
               FASTLANE_SKIP_UPDATE_CHECK='1', FASTLANE_DISABLE_COLORS='1', **extra)
    run('bundle', 'exec', 'fastlane', 'ios', lane, env=env)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('step', choices=['notes', 'archive', 'upload', 'metadata', 'submit', 'status'])
    parser.add_argument('--version', help='候选 App Store 版本；notes 可省略，自动查询线上并升级')
    parser.add_argument('--attempt', type=int, default=1, help='同一版本的第几次构建，默认 1')
    parser.add_argument('--base', help='上次发布的 Git 提交或 tag；生成说明时必填')
    parser.add_argument('--notes-reviewed', action='store_true', help='确认已核对 release-notes.txt 与 changes.md')
    parser.add_argument('--fixed-version', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--adopt-upload', action='store_true', help='上传结果不明时，核实 Apple 已接收同一构建后跳过重传，等待处理')
    args = parser.parse_args()
    if args.step == 'notes' and not args.version:
        project = (ROOT / os.environ.get('RELEASE_PROJECT', 'TimeTrace.xcodeproj') / 'project.pbxproj').read_text()
        versions = set(re.findall(r'MARKETING_VERSION = ([0-9.]+);', project))
        require(len(versions) == 1, '项目版本不唯一，请传入 --version')
        args.version = versions.pop()
    require(args.version and re.fullmatch(r'\d+\.\d+(?:\.\d+)?', args.version), '请指定有效的 --version')
    if args.step == 'notes':
        import tempfile
        with tempfile.TemporaryDirectory(prefix='timetrace-version-') as temp:
            result = Path(temp) / 'version.json'
            call_fastlane('release_resolve', RELEASE_CANDIDATE=args.version, RELEASE_VERSION_RESULT=str(result))
            resolved = json.loads(result.read_text())
            require(not args.fixed_version or args.version == resolved['version'], 'Apple 版本已变化，请重新运行入口')
            args.version = resolved['version']
            print(f'Apple 版本检查完成，本次使用：{args.version}', flush=True)

    require(args.attempt > 0, 'attempt 必须为正整数')
    # Documents 可能由文件同步服务添加 FinderInfo，导致 CodeSign 失败。
    release_root = Path(os.environ.get('TIMETRACE_RELEASE_ROOT',
                        str(Path.home() / 'Library/Developer/TimeTraceReleases'))).expanduser().resolve()
    folder = release_root / args.version / f'attempt-{args.attempt}'
    folder.mkdir(parents=True, exist_ok=True)
    # 同一项目串行归档/上传，避免跨版本并发构建及状态文件竞争。
    with (release_root / '.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        state_path = folder / 'state.json'
        state = json.loads(state_path.read_text()) if state_path.exists() else {'version': args.version, 'bundle_id': BUNDLE}
        notes_path = folder / 'release-notes.txt'
        def save():
            temporary = folder / 'state.tmp'
            temporary.write_text(json.dumps(state, ensure_ascii=False, indent=2) + '\n')
            temporary.replace(state_path)
        def notes():
            require(notes_path.exists(), '先运行 notes，并核对生成的更新说明')
            content = notes_path.read_text().strip()
            require(0 < len(content) <= 4000, '更新说明不能为空或超过 4000 字符')
            require(len(content.encode('utf-8')) <= 4000, 'TestFlight 说明不能超过 4000 UTF-8 字节，请缩短中文说明')
            return content
        def fastlane(lane):
            extra = {'RELEASE_DIR': str(folder)}
            if args.adopt_upload:
                extra['RELEASE_ADOPT_UPLOAD'] = '1'
            call_fastlane(lane, **extra)
        if args.step == 'status':
            print(json.dumps(state, ensure_ascii=False, indent=2))
            print(f'产物目录：{folder}\n这是本地记录；Apple 当前审核状态请在 App Store Connect 核实。')
            return
        if args.step == 'notes':
            require(not notes_path.exists() and 'ipa' not in state, '该版本已有发布资料；请编辑现有文件，不自动覆盖')
            require(args.base, '用 --base 指定上次实际上线的提交或 tag；不能可靠猜测发布基线')
            base = run('git', 'rev-parse', '--verify', '--end-of-options', args.base + '^{commit}', capture=True)
            run('git', 'merge-base', '--is-ancestor', base, 'HEAD')
            subjects = run('git', 'log', '--no-merges', '--format=%s', f'{base}..HEAD', capture=True)
            entries = []
            for line in subjects.splitlines():
                if re.match(r'^(docs|test|tests|ci|build|chore)(\([^)]*\))?:', line, re.I):
                    continue
                clean = re.sub(r'^(feat|fix|perf|refactor)(\([^)]*\))?!?:\s*', '', line, flags=re.I)
                if clean not in entries:
                    entries.append(clean)
            notes_path.write_text('\n'.join('- ' + line for line in entries) + '\n')
            changes = run('git', 'log', '--format=%h %s', f'{base}..HEAD', capture=True)
            diff = run('git', 'diff', '--stat', base, capture=True)
            working = run('git', 'status', '--short', capture=True)
            (folder / 'changes.md').write_text(
                f'# {args.version} 更新说明依据\n\n基线：{base}\n\n## 提交\n\n{changes}\n\n'
                f'## 含工作区的差异\n\n```text\n{diff}\n```\n\n## 工作区与新增文件\n\n```text\n{working}\n```\n\n'
                'release-notes.txt 是由提交标题整理的草稿。请改为面向用户的中文，并根据上面的工作区改动补充内容；'
                '脚本不会推断未提交代码的功能，也不把文件名当作已完成功能。\n')
            state.update(base=base, source=snapshot(), head=run('git', 'rev-parse', 'HEAD', capture=True))
            save()
            print(f'已生成：{notes_path}\n请结合 changes.md 编辑、核对后运行 archive。')
            return
        if args.step == 'archive':
            if state.get('ipa'):
                require(Path(state['ipa']).is_file() and digest(Path(state['ipa'])) == state['ipa_sha256'], '已导出 IPA 缺失或校验不一致')
                print('归档与导出已完成，跳过。')
                return
            notes()
            fastlane('release_check')
            env = os.environ.copy()
            env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
            archive = folder / 'TimeTrace.xcarchive'
            if not state.get('archive_complete'):
                require(source_matches(state), '源码发生变化，请在入口选择新构建，避免文案与代码不一致')
                if archive.exists():
                    import time
                    archive.rename(folder / f'failed-{time.time_ns()}.xcarchive')
                run('xcodebuild', '-project', str(ROOT / os.environ.get('RELEASE_PROJECT', 'TimeTrace.xcodeproj')),
                    '-scheme', os.environ.get('RELEASE_SCHEME', 'TimeTrace'),
                    '-configuration', 'Release', '-destination', 'generic/platform=iOS',
                    '-archivePath', str(archive), '-derivedDataPath', str(folder / 'DerivedData'),
                    '-allowProvisioningUpdates', f'MARKETING_VERSION={args.version}', 'archive', env=env)
                require(source_matches(state), '归档期间源码发生变化，请创建新构建')
                state['archive_complete'] = True
                save()
            else:
                require(archive.exists(), '已完成的归档丢失，请创建新构建')
                print('归档已完成，跳过归档，继续导出。')
            info_path = archive / 'Products/Applications/TimeTrace.app/Info.plist'
            with info_path.open('rb') as stream:
                info = plistlib.load(stream)
            require(info['CFBundleIdentifier'] == BUNDLE and info['CFBundleShortVersionString'] == args.version,
                    '归档的包标识或版本不匹配')
            export = folder / 'ExportOptions.plist'
            with (ROOT / os.environ.get('RELEASE_EXPORT_OPTIONS', 'AppStoreAssets/ExportOptions.plist')).open('rb') as stream:
                options = plistlib.load(stream)
            options.update(destination='export', manageAppVersionAndBuildNumber=False)
            with export.open('wb') as stream:
                plistlib.dump(options, stream)
            run('xcodebuild', '-exportArchive', '-archivePath', str(archive), '-exportPath', str(folder / 'export'),
                '-exportOptionsPlist', str(export), '-allowProvisioningUpdates', env=env)
            ipas = list((folder / 'export').glob('*.ipa'))
            require(len(ipas) == 1, '导出的 IPA 数量不正确')
            with zipfile.ZipFile(ipas[0]) as ipa:
                app_infos = [n for n in ipa.namelist() if re.fullmatch(r'Payload/[^/]+\.app/Info.plist', n)]
                require(len(app_infos) == 1, 'IPA 主应用不唯一')
                exported = plistlib.loads(ipa.read(app_infos[0]))
            for key in ['CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion']:
                require(exported[key] == info[key], f'导出改变了 {key}')
            state.update(ipa=str(ipas[0]), ipa_sha256=digest(ipas[0]), build=str(info['CFBundleVersion']))
            save()
            print(f'归档完成：{args.version} ({state["build"]})；尚未上传。')
            return
        require('ipa' in state, '先运行 archive')
        require(Path(state['ipa']).is_file() and digest(Path(state['ipa'])) == state['ipa_sha256'], 'IPA 缺失或已变化')
        if args.step == 'upload' and state.get('uploaded'):
            print('上传已完成，跳过。')
            return
        if args.step == 'submit' and state.get('submitted'):
            print('审核已提交，跳过。')
            return
        notes()
        if args.step == 'metadata' and state.get('metadata_sha256') == digest(notes_path):
            print('相同更新说明已填写，跳过。')
            return
        if args.step == 'upload':
            require(not state.get('uploaded'), '此构建已经上传并处理完成，请继续 metadata')
            require(args.notes_reviewed, '请先核对更新说明，再加 --notes-reviewed')
            # 失败时不标记成功，不自动重传可能已被 Apple 接收的二进制。
            fastlane('release_upload')
            state['uploaded'] = True
        elif args.step == 'metadata':
            require(state.get('uploaded'), '先完成 upload，等待 Apple 处理成功')
            require(not state.get('submitted'), '已经提交审核，不能再通过此流程覆盖资料')
            require(args.notes_reviewed, '请先核对更新说明，再加 --notes-reviewed')
            fastlane('release_metadata')
            state['metadata_sha256'] = digest(notes_path)
        else:
            require(state.get('metadata_sha256') == digest(notes_path), '先运行 metadata；更新说明变化后需要重新填写')
            require(not state.get('submitted'), '此版本已经提交审核，不重复提交')
            fastlane('release_submit')
            state['submitted'] = True
        save()
        print(f'{args.step} 完成：{args.version} ({state["build"]})')

if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, KeyError, zipfile.BadZipFile) as error:
        print(f'发布步骤停止：{error}', file=sys.stderr)
        sys.exit(1)
