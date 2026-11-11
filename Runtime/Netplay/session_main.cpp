// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#include "gns_lan.h"
#include "lockstep.h"
#include "emu_runtime.h"
#include <openssl/sha.h>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <thread>
#include <memory>
#include <iomanip>
#include <dlfcn.h>
#include <algorithm>
using namespace emu;
using Clock=std::chrono::steady_clock;
using Hash=std::array<uint8_t,32>;
static Hash hash(const Bytes &b) { Hash h;SHA256(b.data(),b.size(),h.data());return h; }
static std::string hex(const Hash &h) {std::ostringstream s;for(auto b:h)s<<std::hex<<std::setw(2)<<std::setfill('0')<<unsigned(b);return s.str();}
static Bytes read(const std::string &path) {std::ifstream f(path,std::ios::binary);if(!f)throw std::runtime_error("cannot read "+path);return Bytes(std::istreambuf_iterator<char>(f),{});}
static void check(int32_t result) {if(result)throw std::runtime_error("runtime error "+std::to_string(result));}
static void addHash(Bytes &b,const Hash &h) {b.insert(b.end(),h.begin(),h.end());}
static Hash getHash(Reader &r) {Hash h;for(auto &b:h)b=uint8_t(r.get(1));return h;}
int main(int argc,char **argv) {
 try {
    std::map<std::string,std::string> args;
    const std::vector<std::string> allowed={"--mode","--address","--rom","--runtime","--trace","--out","--session","--frames","--delay","--lag","--loss","--realtime","--timeout","--stall-at","--stall-ms","--drop-at","--profile-tag"};
    for(int i=1;i<argc;i+=2) {
        if(i+1==argc || std::find(allowed.begin(),allowed.end(),argv[i])==allowed.end() || !args.emplace(argv[i],argv[i+1]).second)
            throw std::runtime_error("unknown, duplicate or valueless option");
    }
    auto value=[&](const std::string &key,std::string fallback="") {auto i=args.find(key);if(i!=args.end())return i->second;if(fallback.empty())throw std::runtime_error("missing "+key);return fallback;};
    auto number=[&](const std::string &key,uint64_t def,uint64_t max) {auto s=value(key,std::to_string(def));size_t pos=0;auto n=std::stoull(s,&pos);if(pos!=s.size() || n>max)throw std::runtime_error("invalid "+key);return n;};
    std::string mode=value("--mode");bool offline=mode=="offline",host=mode=="host";
    if(!offline && !host && mode!="join")throw std::runtime_error("mode must be offline, host or join");
    unsigned role=host?0:1;
    uint32_t frames=number("--frames",7200,1000000),delay=number("--delay",3,12);
    uint64_t session=number("--session",1,UINT64_MAX);
    if(!session || frames<delay+1)throw std::runtime_error("invalid session/frame count");
    uint32_t timeout=number("--timeout",10000,60000),lag=number("--lag",0,1000),loss=number("--loss",0,50);
    if(timeout<100)throw std::runtime_error("timeout too short");
    uint32_t stallAt=number("--stall-at",0,frames),stallMs=number("--stall-ms",0,60000),dropAt=number("--drop-at",0,frames);
    bool realtime=number("--realtime",0,1);
    auto out=std::filesystem::path(value("--out"));
    if(!std::filesystem::create_directory(out))throw std::runtime_error("output directory already exists");
    auto rom=read(value("--rom"));
    auto coreHash=hash(read(value("--runtime"))), exeHash=hash(read(std::filesystem::canonical(argv[0]).string()));
    // Verify the digest names the actual loaded library, including loader overrides.
    auto colocated=std::filesystem::canonical(argv[0]).parent_path()/"libemu_snes.dylib";
    Dl_info loaded{};
    if(!dladdr(reinterpret_cast<void*>(&emu_create), &loaded) || !std::filesystem::equivalent(loaded.dli_fname,value("--runtime")) || !std::filesystem::equivalent(colocated,value("--runtime")))throw std::runtime_error("runtime must be colocated with executable");
    std::ifstream input(value("--trace"));if(!input)throw std::runtime_error("missing trace");
    std::vector<std::array<uint16_t,2>> trace;
    std::string line;
    while(trace.size()<frames-delay && std::getline(input,line)) {
        std::istringstream row(line);uint32_t n,a,b;std::string extra;
        if(!(row>>n>>a>>b) || (row>>extra) || n!=trace.size()+1 || a>4095 || b>4095)throw std::runtime_error("bad trace");
        trace.push_back({uint16_t(a),uint16_t(b)});
    }
    if(trace.size()!=frames-delay)throw std::runtime_error("trace too short");
    emu_runtime *raw=nullptr;check(emu_create(EMU_RUNTIME_ABI,rom.data(),uint32_t(rom.size()),&raw));
    std::unique_ptr<emu_runtime,decltype(&emu_destroy)> runtime(raw,emu_destroy);
    uint32_t size;check(emu_state_size(raw,&size));Bytes state(size);
    auto snapshot=[&] {check(emu_state_copy(raw,state.data(),size));return hash(state);};
    Hash initial=snapshot(),last=initial;
    std::ofstream log(out/"states.hashes");log<<"0 "<<size<<" "<<hex(initial)<<"\n";
    Lockstep schedule(delay);
    std::map<uint32_t,Hash> localHashes,remoteHashes;
    uint64_t stalledPolls=0;
    auto compare=[&] {
        for(auto i=remoteHashes.begin();i!=remoteHashes.end();) {
            auto l=localHashes.find(i->first);
            if(l==localHashes.end()) {++i;continue;}
            if(l->second!=i->second)throw std::runtime_error("state mismatch at frame "+std::to_string(i->first));
            localHashes.erase(l);i=remoteHashes.erase(i);
        }
        if(localHashes.size()>8 || remoteHashes.size()>8)throw std::runtime_error("checkpoint queue full");
    };
    std::unique_ptr<Lan> lan;
    if(!offline)lan.reset(new Lan(host,value("--address"),lag,float(loss)));
    auto hello=[&](unsigned player) {
        Bytes b;append(b,player,1);append(b,delay,4);append(b,frames,4);
        addHash(b,exeHash);addHash(b,coreHash);addHash(b,hash(rom));addHash(b,initial);
        std::string profile=std::string(emu_runtime_profile())+value("--profile-tag","none");
        append(b,profile.size(),2);b.insert(b.end(),profile.begin(),profile.end());
        return packet(Kind::Hello,session,b);
    };
    bool sentHello=false,gotHello=false,running=offline,sentDone=false,gotDone=false,gotAck=false,sentAck=false;
    auto start=Clock::now(),progress=start,pace=start;
    bool stalledOnce=false;Clock::time_point stallUntil{};
    uint32_t sampled=0;
    auto sendHash=[&](Kind kind,uint32_t frame,Hash h){Bytes b;append(b,frame,4);addHash(b,h);lan->send(packet(kind,session,b));};
    while(true) {
        if(lan) {
            lan->poll([&](const Bytes &b) {
                Reader r{b};auto kind=header(r,session);
                if(kind==Kind::Hello) {
                    if(gotHello || b!=hello(1-role))throw std::runtime_error("incompatible session handshake");
                    if(!sentHello){lan->send(hello(role));sentHello=true;}
                    gotHello=true;lan->send(packet(Kind::Ready,session));progress=Clock::now();return;
                }
                if(kind==Kind::Ready) {
                    r.end();if(!gotHello || running)throw std::runtime_error("unexpected ready");
                    running=true;progress=pace=Clock::now();return;
                }
                if(!running)throw std::runtime_error("message before ready");
                if(kind==Kind::Input) {
                    auto frame=uint32_t(r.get(4));auto mask=uint16_t(r.get(2));auto player=r.get(1);r.end();
                    if(player!=1-role || frame<=delay || frame>frames)throw std::runtime_error("invalid input owner/frame");
                    schedule.put(unsigned(player),frame,mask);return;
                }
                if(kind==Kind::Hash || kind==Kind::Done) {
                    auto frame=uint32_t(r.get(4));auto h=getHash(r);r.end();
                    if(kind==Kind::Done) {
                        if(frame!=frames || gotDone)throw std::runtime_error("unexpected completion");
                        gotDone=true;remoteHashes[frame]=h;
                    } else {
                        if(!frame || frame%60 || frame>=frames || frame>schedule.next()+Lockstep::Window || frame+Lockstep::History<schedule.next())throw std::runtime_error("checkpoint outside window");
                        auto old=remoteHashes.find(frame);
                        if(old!=remoteHashes.end() && old->second!=h)throw std::runtime_error("conflicting hash");
                        remoteHashes[frame]=h;
                    }
                    compare();return;
                }
                if(kind==Kind::Ack) {
                    r.end();if(!sentDone || !gotDone)throw std::runtime_error("unexpected final ack");gotAck=true;return;
                }
            });
            if(lan->connected() && !sentHello) {lan->send(hello(role));sentHello=true;}
        }
        auto now=Clock::now();
        if(now-progress>std::chrono::milliseconds(timeout))throw std::runtime_error("no-progress timeout at frame "+std::to_string(schedule.next()));
        if(!running) {std::this_thread::sleep_for(std::chrono::milliseconds(1));continue;}
        uint32_t frame=schedule.next();
        if(frame>frames) {
            if(offline)break;
            if(!sentDone) {localHashes[frames]=last;sendHash(Kind::Done,frames,last);sentDone=true;compare();}
            if(gotDone && localHashes.empty() && remoteHashes.empty()) {
                // Reliable ordered ACK follows our DONE; both peers verify final hashes.
                if(!sentAck){lan->send(packet(Kind::Ack,session));sentAck=true;}
                if(gotAck)break;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(1));continue;
        }
        if(frame==dropAt)throw std::runtime_error("injected disconnect");
        if(frame==stallAt && !stalledOnce){stalledOnce=true;stallUntil=now+std::chrono::milliseconds(stallMs);}
        bool held=stalledOnce && now<stallUntil;
        if(!held && sampled!=frame && schedule.sampleFrame()<=frames) {
            auto target=schedule.sampleFrame();
            if(offline) {schedule.put(0,target,trace[frame-1][0]);schedule.put(1,target,trace[frame-1][1]);}
            else {
                auto mask=trace[frame-1][role];schedule.put(role,target,mask);
                Bytes b;append(b,target,4);append(b,mask,2);append(b,role,1);lan->send(packet(Kind::Input,session,b));
            }
            sampled=frame;
        }
        bool due=!realtime || now>=pace;
        if(!held && schedule.ready() && due) {
            auto pair=schedule.take();emu_frame view{};check(emu_step(raw,pair[0],pair[1],&view));
            last=snapshot();log<<frame<<" "<<size<<" "<<hex(last)<<"\n";
            if(lan && frame%60==0 && frame<frames) {localHashes[frame]=last;sendHash(Kind::Hash,frame,last);compare();}
            progress=Clock::now();pace=progress+std::chrono::microseconds(16639);
        } else {++stalledPolls;std::this_thread::sleep_for(std::chrono::milliseconds(1));}
    }
    log.close();
    if(lan) {
        // Give the final reliable ACK time to leave before global GNS shutdown.
        auto until=Clock::now()+std::chrono::milliseconds(200);
        while(Clock::now()<until) {try {lan->poll([](const Bytes&){});}catch(...){break;}std::this_thread::sleep_for(std::chrono::milliseconds(2));}
    }
    std::ofstream report(out/"report.json");
    report<<"{\"result\":\"PASS\",\"mode\":\""<<mode<<"\",\"frames\":"<<frames<<",\"delay\":"<<delay
          <<",\"stalled_polls\":"<<stalledPolls<<",\"lag_ms\":"<<lag<<",\"loss_percent\":"<<loss
          <<",\"final_state_sha256\":\""<<hex(last)<<"\",\"state_log_sha256\":\""<<hex(hash(read((out/"states.hashes").string())))<<"\"}\n";
    std::cout<<"PASS "<<mode<<" frames="<<frames<<" final="<<hex(last)<<std::endl;
    return 0;
 } catch(const std::exception &e) {std::cerr<<"FAIL: "<<e.what()<<std::endl;return 1;}
}
