#!/usr/bin/env python3
# Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
"""Focused local process integration: transport + actual emulation + failures."""
import argparse,json,subprocess,time
from pathlib import Path

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--exe',type=Path,required=True);p.add_argument('--rom',type=Path,required=True)
    p.add_argument('--trace',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--port',type=int,default=27880)
    a=p.parse_args();a.output.mkdir(parents=True,exist_ok=False)
    exe=a.exe.resolve();runtime=exe.parent/'libemu_snes.dylib'
    rows=[list(map(int,line.split())) for line in a.trace.read_text().splitlines()]
    # Deliberately corrupt the other player's trace column. Matching the offline
    # oracle proves each peer obtained the remote inputs over the transport.
    for role in (0,1):
        text=''.join(f'{f} {x if role==0 else 0} {y if role==1 else 0}\n' for f,x,y in rows)
        (a.output/f'player-{role}.txt').write_text(text)
    base=[str(exe),'--rom',str(a.rom.resolve()),'--runtime',str(runtime),'--session','814773','--delay','3']
    results=[]
    def pair(name,frames,host_extra=(),join_extra=(),success=True):
        addr=f'127.0.0.1:{a.port}'
        handles=[];processes=[]
        try:
            for role,extra in [(0,host_extra),(1,join_extra)]:
                mode='host' if role==0 else 'join';out=a.output/f'{name}-{mode}'
                log=(a.output/f'{name}-{mode}.log').open('w');handles.append(log)
                cmd=base+['--mode',mode,'--address',addr,'--trace',str((a.output/f'player-{role}.txt').resolve()),'--out',str(out.resolve()),'--frames',str(frames)]+list(extra)
                processes.append(subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT))
                if role==0:time.sleep(.15)
            codes=[p.wait(timeout=90) for p in processes]
            if success:
                assert codes==[0,0],(name,codes)
                host=json.loads((a.output/f'{name}-host/report.json').read_text());join=json.loads((a.output/f'{name}-join/report.json').read_text())
                assert host['state_log_sha256']==join['state_log_sha256']
                offline=a.output/f'{name}-offline'
                subprocess.run(base+['--mode','offline','--trace',str(a.trace.resolve()),'--out',str(offline.resolve()),'--frames',str(frames)],stdout=subprocess.DEVNULL,check=True,timeout=90)
                oracle=json.loads((offline/'report.json').read_text())
                assert host['state_log_sha256']==oracle['state_log_sha256']
                results.append({'case':name,'result':'PASS','host':host,'join':join,'offline_matches':True})
            else:
                assert all(code!=0 for code in codes),(name,codes)
                assert not any((a.output/f'{name}-{m}/report.json').exists() for m in ('host','join'))
                results.append({'case':name,'result':'EXPECTED_FAILURE','exit_codes':codes})
        finally:
            for proc in processes:
                if proc.poll() is None:proc.kill();proc.wait()
            for log in handles:log.close()
    pair('clean',7203)
    # Same port immediately reused after teardown. GNS injects latency and loss.
    pair('impaired',903,['--lag','15','--loss','2'],['--lag','15','--loss','2','--stall-at','300','--stall-ms','250'])
    pair('mismatch',303,join_extra=['--profile-tag','different'],success=False)
    pair('disconnect',603,join_extra=['--drop-at','200'],success=False)
    pair('timeout',603,['--timeout','300'],['--timeout','300','--stall-at','200','--stall-ms','1000'],False)
    (a.output/'report.json').write_text(json.dumps({'result':'PASS','cases':results},indent=2)+'\n')
    print(json.dumps({'result':'PASS','cases':[x['case'] for x in results]}))
if __name__=='__main__':main()
