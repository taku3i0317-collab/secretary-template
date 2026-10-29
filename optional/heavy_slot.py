"""重い処理の順番待ち（枠）。グラボの枠と CPU の枠を分けて数える。Python 3 の標準だけ。

    python heavy_slot.py run --name 作業名 -- <重いコマンド...>
    python heavy_slot.py run --name 作業名 --device cpu --mem 4 -- <コマンド...>
    python heavy_slot.py status

--device gpu（決めないときはこれ）: グラボの枠が空くまで待つ（描き出し・焼き付け・学習）
--device cpu: CPU の枠（シミュレーション・全件の検査など、グラボを使わない重い処理）
--device any: どちらか先に空いた方（グラボを先に見る）
--mem GB: この仕事のメモリの見込み。足りなければ、後ろの小さい仕事が先に入れる

考え方（くわしくは optional/重い処理の順番待ちとGPU.md）:
  1. 枠の数に上限を置く（グラボ・CPU・全部で何本まで）
  2. スレッドは「空き」に合わせる：全スレッド − 画面用に残す分 − (今の CPU 使用率から出した使用中 と 動いている重い処理の合計 の大きい方)
  3. 画面の余裕を残す：空きメモリ・空き VRAM が「見込み＋画面用」に足りなければ始めない
  4. 待ちは列から落ちない：待ちの札（wait/<PID>.json）が消されても同じ順番で戻る。持ち主が死んだ枠・札は空きとみなす

設定は BASE/config.json（無ければ DEFAULT）。BASE は環境変数 HEAVY_SLOT_BASE、無ければ ~/.heavy_slot。
子のプロセスには環境変数 HEAVY_SLOT_DEVICE（gpu か cpu）・HEAVY_SLOT_THREADS・OMP_NUM_THREADS 等を渡す
（使う側のプログラムがこれに従って、装置とスレッド数を決める）。
"""
import ctypes, datetime, json, os, shutil, subprocess, sys, time

BASE = os.environ.get('HEAVY_SLOT_BASE') or os.path.join(os.path.expanduser('~'), '.heavy_slot')
WAIT = os.path.join(BASE, 'wait')
# 枠の数の上限と、画面のための余裕（自分の PC に合わせて BASE/config.json で上書きする）
DEFAULT = {'gpu': 1, 'cpu': 2, 'total': 3,
           'threads_total': os.cpu_count() or 4, 'threads_reserve': 2, 'threads_max_cpu': 8, 'threads_max_gpu': 4,
           'threads_start_cpu': 2, 'ram_reserve_gb': 1.0, 'job_mem_gb': 1.5, 'vram_reserve_gb': 2.0, 'vram_per_job_gb': 3.0}
POLL = 5        # 空きを見る間隔（秒）
NEW_GRACE = 30  # owner.json を書く前の枠は、この秒数までは生きているとみなす
BELOW_NORMAL = 0x4000  # 子のプロセスの優先度を下げる（画面・操作を先にする。Windows）


def config():
    c = dict(DEFAULT)
    try:
        c.update(json.load(open(os.path.join(BASE, 'config.json'), encoding='utf-8')))
    except Exception:
        pass
    return c


def slot_dirs(kind):
    return [os.path.join(BASE, f'{kind}{i}') for i in range(1, int(config()[kind]) + 1)]


def read_json(p):
    try:
        return json.load(open(p, encoding='utf-8'))
    except Exception:
        return None


def write_json(p, obj):
    """書きかけを読まれないよう、写しに書いてから入れ替える"""
    tmp = f'{p}.{os.getpid()}.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
    for _ in range(20):
        try:
            os.replace(tmp, p)
            return
        except PermissionError:  # 読んでいる人がいると Windows では入れ替えられないことがある
            time.sleep(0.05)
    os.replace(tmp, p)


def proc_start(pid):
    """プロセスの作られた時刻。無ければ None（死んでいる）。PID の使い回しを見分けるため"""
    if os.name != 'nt':
        try:
            os.kill(pid, 0)
            return 0
        except OSError:
            return None
    k = ctypes.windll.kernel32
    h = k.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        return None
    try:
        code = ctypes.c_ulong()
        if not k.GetExitCodeProcess(h, ctypes.byref(code)) or code.value != 259:  # STILL_ACTIVE
            return None
        c, e, kt, ut = (ctypes.c_ulonglong() for _ in range(4))
        if not k.GetProcessTimes(h, ctypes.byref(c), ctypes.byref(e), ctypes.byref(kt), ctypes.byref(ut)):
            return 0
        return c.value
    finally:
        k.CloseHandle(h)


def alive(info):
    st = proc_start(info.get('pid', -1))
    return st is not None and (not info.get('pid_start') or st == info['pid_start'])


def holder(slot):
    """枠の持ち主。空き（フォルダが無い・持ち主が死んでいる）なら None。取ったばかりの枠は {'_new': True}"""
    if not os.path.isdir(slot):
        return None
    info = read_json(os.path.join(slot, 'owner.json'))
    if info is None:
        try:
            return {'_new': True} if time.time() - os.path.getmtime(slot) <= NEW_GRACE else None
        except OSError:
            return None
    return info if alive(info) else None


def break_slot(slot):
    """死んだ枠を片付ける。名前を変えてから消す（2 人が同時に片付けても 1 人だけが成功する）"""
    tmp = f'{slot}.stale.{os.getpid()}.{time.time_ns()}'
    try:
        os.rename(slot, tmp)
    except OSError:
        return
    shutil.rmtree(tmp, ignore_errors=True)


def try_take(kind, info):
    """mkdir で枠を取る（同時に 2 人は取れない）"""
    for slot in slot_dirs(kind):
        try:
            os.mkdir(slot)
        except FileExistsError:
            if holder(slot) is not None:
                continue
            break_slot(slot)
            try:
                os.mkdir(slot)
            except FileExistsError:
                continue
        write_json(os.path.join(slot, 'owner.json'), dict(info, slot=os.path.basename(slot), kind=kind))
        return slot
    return None


def release(slot):
    info = read_json(os.path.join(slot, 'owner.json'))
    if info and info.get('pid') == os.getpid():
        break_slot(slot)


def waiters():
    """待ちの列（来た順）。持ち主が死んだ札は消す。読めない札は書いている途中かもしれないので 2 分までは消さない"""
    out = []
    for p in os.listdir(WAIT) if os.path.isdir(WAIT) else []:
        if not p.endswith('.json'):
            continue
        fp = os.path.join(WAIT, p)
        info = read_json(fp)
        if info is None:
            try:
                if time.time() - os.path.getmtime(fp) > 120:
                    os.remove(fp)
            except OSError:
                pass
            continue
        if alive(info):
            out.append(info)
        else:
            try:
                os.remove(fp)
            except OSError:
                pass
    return sorted(out, key=lambda w: w.get('enq', 0))


def ram():
    """メモリ（GB）。取れなければ None"""
    try:
        class MS(ctypes.Structure):
            _fields_ = [('l', ctypes.c_ulong), ('load', ctypes.c_ulong), ('tot', ctypes.c_ulonglong), ('avail', ctypes.c_ulonglong)] + \
                       [(f'x{i}', ctypes.c_ulonglong) for i in range(5)]
        m = MS(); m.l = ctypes.sizeof(MS)
        ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(m))
        return dict(used_gb=round((m.tot - m.avail) / 2**30, 1), total_gb=round(m.tot / 2**30, 1))
    except Exception:
        return None


def cpu_percent(dt=0.5):
    """今の CPU 使用率（%）。取れなければ None"""
    try:
        if os.name != 'nt':
            return round(100 * os.getloadavg()[0] / (os.cpu_count() or 1))

        def t():
            i, k, u = (ctypes.c_ulonglong() for _ in range(3))
            ctypes.windll.kernel32.GetSystemTimes(ctypes.byref(i), ctypes.byref(k), ctypes.byref(u))
            return i.value, k.value + u.value
        i0, t0 = t(); time.sleep(dt); i1, t1 = t()
        return round(100 * (1 - (i1 - i0) / max(1, t1 - t0)))
    except Exception:
        return None


def vram():
    """グラボのメモリ（nvidia-smi がある PC だけ）。無ければ None（＝グラボの余裕は見ない）"""
    try:
        r = subprocess.run(['nvidia-smi', '--query-gpu=memory.used,memory.total', '--format=csv,noheader,nounits'],
                           capture_output=True, text=True, timeout=10)
        u, t = [x.strip() for x in r.stdout.strip().splitlines()[0].split(',')]
        return dict(used_mb=int(u), total_mb=int(t))
    except Exception:
        return None


def threads_in_use():
    """動いている重い処理の -t（スレッド数）の合計"""
    c = config()
    n = 0
    for kind in ('gpu', 'cpu'):
        for s in slot_dirs(kind):
            h = holder(s)
            if h is not None:
                n += int(h.get('threads') or 0) or c[f'threads_max_{kind}']
    return n


def free_threads():
    """画面用を残した空きスレッド数 ＝ 全部 − 画面用 − max(使用率から出した使用中, 重い処理の合計)"""
    c = config()
    measured = round((cpu_percent(1.0) or 0) * c['threads_total'] / 100)
    return c['threads_total'] - c['threads_reserve'] - max(measured, threads_in_use())


def my_turn(me):
    """来た順に、空いている枠・メモリ・スレッドを割り当ててみる。自分の番なら (枠の種類, スレッド数) を返す。
    大きい仕事が入らないときは、後ろの小さい仕事が先に入れる"""
    c = config()
    free = {k: sum(1 for s in slot_dirs(k) if holder(s) is None) for k in ('gpu', 'cpu')}
    busy = (c['gpu'] + c['cpu']) - free['gpu'] - free['cpu']
    free['total'] = max(0, int(c['total']) - busy)
    r, v = ram(), vram()
    mem = ((r['total_gb'] - r['used_gb']) if r else 99.0) - c['ram_reserve_gb']
    vr = ((v['total_mb'] - v['used_mb']) / 1024) if v else 99.0
    gpu_ok = vr >= c['vram_reserve_gb'] + c['vram_per_job_gb']
    ft = free_threads()
    for w in waiters():
        dev, need = w.get('want', 'gpu'), float(w.get('mem') or c['job_mem_gb'])
        got, why = None, ''
        if free['total'] <= 0:
            why = f"全部で {c['total']} 本が動いている"
        elif need > mem:
            why = f"空きメモリが足りない（この仕事の見込み {need} GB ＋ 画面用 {c['ram_reserve_gb']} GB）"
        elif dev in ('gpu', 'any') and free['gpu'] > 0 and gpu_ok and ft >= 1:
            got = ('gpu', max(1, min(ft, c['threads_max_gpu'])))
        elif dev in ('cpu', 'any') and free['cpu'] > 0 and ft >= c['threads_start_cpu']:
            got = ('cpu', max(1, min(ft, c['threads_max_cpu'])))
        elif dev in ('gpu', 'any') and free['gpu'] > 0 and not gpu_ok:
            why = f"VRAM の空きが足りない（{vr:.1f} GB。画面用 {c['vram_reserve_gb']} ＋ 1 本 {c['vram_per_job_gb']} GB が要る）"
        elif ft < (1 if dev == 'gpu' else c['threads_start_cpu']):
            why = f"CPU が混んでいる（空きスレッド {max(ft, 0)}。画面用に {c['threads_reserve']} 残す）"
        else:
            why = f"{dev} の枠が空いていない"
        if got:
            free[got[0]] -= 1
            free['total'] -= 1
            mem -= need
            ft -= got[1]
        if w.get('pid') == me['pid']:
            me['_why'] = why
            return got
    return None


def run(argv):
    name = os.environ.get('HEAVY_SLOT_NAME') or os.path.basename(os.getcwd())
    want, mem = 'gpu', None
    while argv[:1] in (['--name'], ['--device'], ['--mem']):
        if argv[0] == '--name':
            name = argv[1]
        elif argv[0] == '--mem':
            mem = float(argv[1])
        else:
            want = argv[1].lower()
        argv = argv[2:]
    if argv[:1] == ['--']:
        argv = argv[1:]
    if not argv or want not in ('gpu', 'cpu', 'any'):
        print('使い方: heavy_slot.py run [--name 名前] [--device gpu|cpu|any] [--mem GB] -- <コマンド...>')
        return 2
    os.makedirs(WAIT, exist_ok=True)
    now = datetime.datetime.now().isoformat(timespec='seconds')
    me = dict(pid=os.getpid(), pid_start=proc_start(os.getpid()), session=name, want=want, mem=mem, since=now,
              enq=time.time_ns(), command=subprocess.list2cmdline(argv), cwd=os.getcwd())
    wfile = os.path.join(WAIT, f'{os.getpid()}.json')
    write_json(wfile, me)
    slot, kind, n, said, t0 = None, None, None, '', time.time()
    try:
        while slot is None:
            if not os.path.exists(wfile):  # 自分の札が消されていたら、同じ順番（enq）で列に戻る
                write_json(wfile, me)
                print('[heavy_slot] 待ちの札が無くなっていたので、列に戻した（順番はそのまま）', flush=True)
            got = my_turn(me)
            if got:
                kind, n = got[0], got[1]
                slot = try_take(kind, dict(me, threads=n, start=datetime.datetime.now().isoformat(timespec='seconds')))
            if slot is None:
                why = me.get('_why') or f'{want} の枠が空いていない'
                if why.split(' ')[0] != said:  # 画面に出すのは、理由の種類が変わったときだけ
                    print(f'[heavy_slot] 待つ: {why}（{POLL} 秒おきに見る）', flush=True)
                    said = why.split(' ')[0]
                time.sleep(POLL)
    except KeyboardInterrupt:
        print('[heavy_slot] 待つのをやめた')
        return 130
    finally:
        try:
            os.remove(wfile)
        except OSError:
            pass
    if said:
        print(f'[heavy_slot] {int(time.time() - t0)} 秒待った', flush=True)
    print(f'[heavy_slot] {os.path.basename(slot)} を取った（スレッド {n}）: {me["command"]}', flush=True)
    t = str(n)
    env = dict(os.environ, HEAVY_SLOT_DEVICE=kind, HEAVY_SLOT_DIR=slot, HEAVY_SLOT_NAME=name, HEAVY_SLOT_THREADS=t,
               OMP_NUM_THREADS=t, MKL_NUM_THREADS=t, OPENBLAS_NUM_THREADS=t)
    child = None
    try:
        child = subprocess.Popen(argv, env=env, creationflags=BELOW_NORMAL if os.name == 'nt' else 0)
        return child.wait()
    except KeyboardInterrupt:
        if child and child.poll() is None:
            child.terminate()
            try:
                child.wait(30)
            except subprocess.TimeoutExpired:
                child.kill()
        return 130
    except FileNotFoundError as e:
        print(f'[heavy_slot] コマンドが見つからない: {e}')
        return 127
    finally:
        release(slot)  # 失敗しても Ctrl+C でも空ける
        print(f'[heavy_slot] {os.path.basename(slot)} を空けた', flush=True)


def status():
    c = config()
    print(f"枠: グラボ {c['gpu']}・CPU {c['cpu']}、全部で同時に {c['total']} 本まで（{BASE}）")
    print(f"CPU {cpu_percent(1.0)} %、重い処理のスレッド合計 {threads_in_use()}、空きスレッド {max(0, free_threads())}"
          f"（{c['threads_total']} のうち画面用に {c['threads_reserve']} 残す）")
    r, v = ram(), vram()
    if r:
        print(f"メモリ {r['used_gb']} / {r['total_gb']} GB 使用")
    if v:
        print(f"VRAM {v['used_mb']} / {v['total_mb']} MB 使用")
    for kind in ('gpu', 'cpu'):
        for s in slot_dirs(kind):
            h = holder(s)
            o = h if h and not h.get('_new') else {}
            print(f"- {os.path.basename(s)}: {'使用中 ' + str(o.get('session', '')) + ' / ' + str(o.get('command', ''))[:80] if h else '空き'}")
    w = waiters()
    print(f'待っている: {len(w)}')
    for x in w:
        print(f"- {x.get('session')}（{x.get('want')}、{x.get('since')} から）: {str(x.get('command'))[:80]}")
    return 0


if __name__ == '__main__':
    a = sys.argv[1:]
    if a[:1] == ['run']:
        sys.exit(run(a[1:]))
    elif a[:1] == ['status']:
        sys.exit(status())
    print(__doc__)
    sys.exit(2)
