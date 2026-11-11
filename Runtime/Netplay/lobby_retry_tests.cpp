// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#include "lobby_retry.h"
#include <iostream>
using namespace emu;
static void require(bool value){if(!value)throw std::runtime_error("Lobby retry policy failed");}
int main(){try{
 auto start=LobbyRetry::Clock::time_point{};LobbyRetry retry;
 for(int code:{0,408,429,500,502,503,504})require(LobbyRetry::transient(code));
 for(int code:{200,301,400,401,403,404,409,413,422,501})require(!retry.failed(code,start));
 require(retry.failed(503,start));require(retry.delay()==std::chrono::milliseconds(500));
 require(retry.failed(0,start+std::chrono::seconds(10)));
 require(!retry.failed(504,start+std::chrono::seconds(19)));
 require(!retry.failed(503,start+std::chrono::seconds(20)));
 retry.succeeded();require(retry.failed(502,start+std::chrono::hours(5)));
 require(!retry.failed(403,start+std::chrono::hours(5)));
 for(int i=0;i<20;++i)require(retry.failed(429,start+std::chrono::hours(5)));
 require(retry.delay()==std::chrono::milliseconds(2000));
 // Lost first response spends five seconds before reporting failure. The
 // deadline remains anchored at send time; backoff plus API timeout must fit.
 retry.succeeded();retry.begin(start);require(retry.canAttempt(start));
 require(retry.failed(0,start+std::chrono::seconds(5)));
 require(retry.failed(0,start+std::chrono::milliseconds(10500)));
 require(!retry.failed(0,start+std::chrono::milliseconds(16500)));
 require(retry.canAttempt(start+std::chrono::seconds(15)));
 require(!retry.canAttempt(start+std::chrono::milliseconds(15001)));
 // A delayed worker wake cannot sneak a request past the admission check.
 require(!retry.canAttempt(start+std::chrono::seconds(30)));
 retry.begin(start+std::chrono::seconds(30));
 require(!retry.canAttempt(start+std::chrono::seconds(30)));
 retry.succeeded();retry.begin(start+std::chrono::seconds(40));
 require(retry.canAttempt(start+std::chrono::seconds(40)));
 std::cout<<"PASS transient recovery deadline, backoff, reset and fatal authorization errors\n";return 0;
}catch(const std::exception &e){std::cerr<<e.what()<<"\n";return 1;}}
