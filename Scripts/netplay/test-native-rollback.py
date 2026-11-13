# Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
import ctypes as c, os, json
from pathlib import Path
import argparse
parser=argparse.ArgumentParser(description="Compare corrected late inputs against a fully known input trace")
parser.add_argument('--runtime',required=True,type=Path)
parser.add_argument('--core',required=True,type=Path)
parser.add_argument('--rom',required=True,type=Path)
parser.add_argument('--system',default='nes',choices=['nes','sg','gba'])
parser.add_argument('--view',default='0',choices=['0','1'])
parser.add_argument('--trace',required=True,type=Path,help='Rows: frame player1_mask player2_mask')
parser.add_argument('--delay',default=3,type=int,choices=range(1,31))
args=parser.parse_args()
os.environ['NX_NETPLAY_VIEW']=args.view
os.environ['NX_NETPLAY_CORE']=str(args.core.resolve());os.environ['NX_NETPLAY_SYSTEM']='openemu.system.'+args.system
l=c.CDLL(str(args.runtime.resolve()))
class Frame(c.Structure):
 _fields_=[('video',c.POINTER(c.c_uint16)),('width',c.c_uint32),('height',c.c_uint32),('pitch',c.c_uint32),('audio',c.POINTER(c.c_int16)),('audio_frames',c.c_uint32)]
l.emu_create.argtypes=[c.c_uint32,c.c_void_p,c.c_uint32,c.POINTER(c.c_void_p)]
l.emu_step.argtypes=[c.c_void_p,c.c_uint16,c.c_uint16,c.POINTER(Frame)]
l.emu_state_size.argtypes=[c.c_void_p,c.POINTER(c.c_uint32)]
l.emu_state_copy.argtypes=[c.c_void_p,c.c_void_p,c.c_uint32];l.emu_state_restore.argtypes=l.emu_state_copy.argtypes
l.emu_destroy.argtypes=[c.c_void_p]
l.emu_runtime_profile.restype=c.c_char_p
rom=args.rom.read_bytes();r=c.c_void_p();assert l.emu_create(1,rom,len(rom),c.byref(r))==0
n=c.c_uint32();assert l.emu_state_size(r,c.byref(n))==0
snap=c.create_string_buffer(n.value)
def step(a,b):
 f=Frame();ret=l.emu_step(r,a,b,c.byref(f));assert ret==0,ret
 assert f.width>0 and f.height>0 and 0<f.audio_frames<2000
 return c.string_at(f.video,f.pitch*f.height*2),c.string_at(f.audio,f.audio_frames*4)

rows=[list(map(int,line.split())) for line in args.trace.read_text().splitlines() if line.strip() and not line.lstrip().startswith('#')]
assert rows and all(len(row)==3 and row[0]==i for i,row in enumerate(rows)), 'Trace must contain contiguous frame numbers starting at zero'
trace=[row[1:] for row in rows]
def capture():
 b=c.create_string_buffer(n.value);assert l.emu_state_copy(r,b,n)==0;return b.raw
def restore(b):assert l.emu_state_restore(r,b,len(b))==0
initial=capture();expected={}
for i,m in enumerate(trace):
 step(*m)
 if ((i+1)%60==0 or i==len(trace)-1):expected[i]=capture()
restore(initial);records={};known={};checks={};local=int(args.view);delay=args.delay
failed=None
for i in range(len(trace)+delay):
 receive=i-delay
 if receive>=0:
  known[receive]=trace[receive][1-local]
  if records[receive][1]!=known[receive]:
   restore(records[receive][0])
   for f in range(receive,min(i,len(trace))):
    remote=known.get(f,known[receive]);records[f]=(capture(),remote)
    masks=[0,0];masks[local]=trace[f][local];masks[1-local]=remote;step(*masks)
    if ((f+1)%60==0 or f==len(trace)-1):checks[f]=capture()
  if ((receive+1)%60==0 or receive==len(trace)-1):
   if expected[receive]!=checks[receive]:
    failed=receive+1;break
  for f in list(records):
   if f<receive:del records[f]
 if i<len(trace):
  remote=known.get(receive,0);records[i]=(capture(),remote);masks=[0,0];masks[local]=trace[i][local];masks[1-local]=remote;step(*masks)
  if ((i+1)%60==0 or i==len(trace)-1):checks[i]=capture()
l.emu_destroy(r)
print(json.dumps(dict(pass_check=failed is None,frames=len(trace),local_player=local+1,delay_frames=delay,first_mismatch=failed)))
raise SystemExit(1 if failed is not None else 0)
