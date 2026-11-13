# Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
import ctypes as c, os, hashlib, json
from pathlib import Path
import argparse
parser=argparse.ArgumentParser(description="NES/Genesis/GBA netplay adapter: checkpoint/replay with both players, video and audio")
parser.add_argument('--runtime',required=True,type=Path)
parser.add_argument('--core',required=True,type=Path)
parser.add_argument('--rom',required=True,type=Path)
parser.add_argument('--system',default='nes',choices=['nes','sg','gba'])
parser.add_argument('--view',default='0',choices=['0','1'])
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
for i in range(120):step((64 if args.system=='nes' else 256 if args.system=='gba' else 1024) if i==60 else 0,0)
assert l.emu_state_copy(r,snap,n)==0
out=[step(8|16 if i%10<5 else 0,32 if i%20<10 else 0) for i in range(180)]
state=c.create_string_buffer(n.value);assert l.emu_state_copy(r,state,n)==0
assert l.emu_state_restore(r,snap,n)==0
replay=[step(8|16 if i%10<5 else 0,32 if i%20<10 else 0) for i in range(180)]
state2=c.create_string_buffer(n.value);assert l.emu_state_copy(r,state2,n)==0
assert out==replay,'video or audio differs after rollback';assert state.raw==state2.raw
print(json.dumps({'profile':l.emu_runtime_profile().decode(),'state':hashlib.sha256(state.raw).hexdigest(),'video':hashlib.sha256(b''.join(x[0] for x in out)).hexdigest(),'audio':hashlib.sha256(b''.join(x[1] for x in out)).hexdigest(),'rollback_frames':180}))
l.emu_destroy(r)
