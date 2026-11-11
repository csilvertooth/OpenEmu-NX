// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#include "emu_runtime.h"
#include "sha256.h"
#include <dlfcn.h>
#include <fstream>
#include <iostream>
#include <iomanip>
#include <sstream>
#include <vector>
#include <memory>
#include <stdexcept>
using Bytes=std::vector<unsigned char>;
static Bytes read(const char *path) {
    std::ifstream f(path,std::ios::binary|std::ios::ate);
    if(!f || f.tellg()<=0 || f.tellg()>16*1024*1024)throw std::runtime_error("invalid file");
    Bytes b(static_cast<size_t>(f.tellg()));f.seekg(0);
    if(!f.read(reinterpret_cast<char*>(b.data()),b.size()))throw std::runtime_error("read failed");return b;
}
static std::string digest(Bytes b) {
    unsigned char hash[32];sha256sum(b.data(),static_cast<unsigned>(b.size()),hash);
    std::ostringstream out;for(auto c:hash)out<<std::hex<<std::setw(2)<<std::setfill('0')<<unsigned(c);return out.str();
}
int main(int argc,char **argv) {
    try {
        if(argc!=2)return 2;
        Bytes rom=read(argv[1]);emu_runtime *raw=nullptr;
        if(emu_create(EMU_RUNTIME_ABI,rom.data(),uint32_t(rom.size()),&raw))return 3;
        std::unique_ptr<emu_runtime,decltype(&emu_destroy)> runtime(raw,emu_destroy);
        uint32_t size;if(emu_state_size(raw,&size))return 4;
        Bytes state(size);if(emu_state_copy(raw,state.data(),size))return 4;
        Dl_info loaded{};if(!dladdr(reinterpret_cast<void*>(&emu_create),&loaded))return 5;
        std::cout<<"{\"protocol\":1,\"profile\":\""<<emu_runtime_profile()<<"\",\"rom_sha256\":\""<<digest(rom)
                 <<"\",\"runtime_sha256\":\""<<digest(read(loaded.dli_fname))<<"\",\"initial_state_sha256\":\""<<digest(state)<<"\"}\n";
        return 0;
    }catch(...){return 1;}
}
