// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#include "access_token.h"
#include <iostream>
#include <thread>
#include <vector>
#include <atomic>
using namespace emu;
static void check(bool ok){if(!ok)throw std::runtime_error("Access token test failed");}
int main(){AccessToken cache;auto now=AccessToken::Clock::time_point{};unsigned issued=0;
 auto refresh=[&](){return std::make_pair(std::string(42,'a')+std::to_string(++issued),600);};
 check(cache.get(now,refresh)==(std::string(42,'a')+"1"));check(cache.get(now+std::chrono::seconds(539),refresh)==(std::string(42,'a')+"1"));
 check(cache.get(now+std::chrono::seconds(540),refresh)==(std::string(42,'a')+"2"));
 check(cache.get(now+std::chrono::seconds(541),refresh,(std::string(42,'a')+"1"))==(std::string(42,'a')+"2"));
 check(cache.get(now+std::chrono::seconds(542),refresh,(std::string(42,'a')+"2"))==(std::string(42,'a')+"3"));
 for(auto bad:{std::string(),std::string("a\nb"),std::string(4097,'x')}){bool rejected=false;try{AccessToken::validate(bad,600);}catch(...){rejected=true;}check(rejected);}
 bool rejected=false;try{AccessToken::validate("valid",0);}catch(...){rejected=true;}check(rejected);
 AccessToken failed;try{failed.get(now,[]()->std::pair<std::string,int>{throw std::runtime_error("offline");});}catch(...){}check(failed.get(now,refresh)==(std::string(42,'a')+"4"));
 AccessToken concurrent;std::atomic<unsigned> calls{0};std::vector<std::thread> workers;
 for(unsigned i=0;i<8;++i)workers.emplace_back([&](){auto token=concurrent.get(now,[&](){++calls;return std::make_pair(std::string(43,'a'),600);});check(token==std::string(43,'a'));});
 for(auto &worker:workers)worker.join();check(calls==1);
 bool timedOut=false;try{concurrent.get(now,refresh,{},AccessToken::Clock::now()-std::chrono::seconds(1));}catch(const AccessTokenTimeout&){timedOut=true;}check(timedOut);
 std::cout<<"PASS access credential expiry, stale401, rejection, failed refresh\n";}
