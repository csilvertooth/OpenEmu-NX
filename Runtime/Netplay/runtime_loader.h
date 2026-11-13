// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#pragma once
#include "../Snes9x/emu_runtime.h"
#include <dlfcn.h>
#include <cstdlib>
#include <cstdio>
#include <string>
struct NXRuntimeAPI {
 decltype(&::emu_runtime_abi) abi;
 decltype(&::emu_runtime_profile) profile;
 decltype(&::emu_create) create;
 decltype(&::emu_destroy) destroy;
 decltype(&::emu_frame_duration_us) duration;
 decltype(&::emu_step) step;
 decltype(&::emu_step_players) stepPlayers;
 decltype(&::emu_state_size) size;
 decltype(&::emu_state_copy) copy;
 decltype(&::emu_state_restore) restore;
 NXRuntimeAPI(){
  void *handle=RTLD_DEFAULT;
  const char *backend=getenv("NX_NETPLAY_BACKEND");
  if(backend && std::string(backend)=="openemu"){
   Dl_info info{};if(!dladdr((void*)&::emu_create,&info))fail();
   std::string path=info.dli_fname;path=path.substr(0,path.find_last_of('/')+1)+"libemu_openemu.dylib";
   handle=dlopen(path.c_str(),RTLD_NOW|RTLD_LOCAL);if(!handle)fail();
  }else if(backend && std::string(backend)!="snes9x")fail();
#define NX_SYMBOL(member,name) member=reinterpret_cast<decltype(member)>(dlsym(handle,name));if(!member)fail();
  NX_SYMBOL(abi,"emu_runtime_abi") NX_SYMBOL(profile,"emu_runtime_profile") NX_SYMBOL(create,"emu_create")
  NX_SYMBOL(destroy,"emu_destroy") NX_SYMBOL(duration,"emu_frame_duration_us") NX_SYMBOL(step,"emu_step")
  NX_SYMBOL(size,"emu_state_size") NX_SYMBOL(copy,"emu_state_copy") NX_SYMBOL(restore,"emu_state_restore")
  stepPlayers=reinterpret_cast<decltype(stepPlayers)>(dlsym(handle,"emu_step_players"));
#undef NX_SYMBOL
 }
 [[noreturn]] static void fail(){const char *error=dlerror();fprintf(stderr,"Network runtime could not load: %s\n",error?error:"unknown backend");exit(70);}
};
static NXRuntimeAPI nxRuntime;
#define emu_runtime_abi nxRuntime.abi
#define emu_runtime_profile nxRuntime.profile
#define emu_create nxRuntime.create
#define emu_destroy nxRuntime.destroy
#define emu_frame_duration_us nxRuntime.duration
#define emu_step nxRuntime.step
#define emu_state_size nxRuntime.size
#define emu_state_copy nxRuntime.copy
#define emu_state_restore nxRuntime.restore

#define emu_step_players nxRuntime.stepPlayers
