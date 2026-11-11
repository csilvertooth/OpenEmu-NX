// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#pragma once
#include <algorithm>
#include <chrono>
#include <stdexcept>
#include <string>
namespace emu {
class LobbyHTTPError:public std::runtime_error {
public:
 const int status;
 LobbyHTTPError(int code,const std::string &message):std::runtime_error(message),status(code){}
};
// Short control-plane outages must not interrupt a healthy game transport.
// Authentication, revoked membership, malformed replies and the outage deadline
// remain fatal. Twenty seconds fits inside the lobby's sixty-second guest lease.
class LobbyRetry {
public:
 using Clock=std::chrono::steady_clock;
 static bool transient(int code){return code==0 || code==408 || code==429 || code==500 || code==502 || code==503 || code==504;}
 // Start before the first HTTP attempt, not after its timeout. Reserve the
 // API's full five-second wait before admitting another attempt.
 void begin(Clock::time_point now){if(!active_){active_=true;started_=now;attempt_=0;}}
 bool canAttempt(Clock::time_point now)const{return active_ && now-started_<=std::chrono::seconds(15);}
 bool failed(int code,Clock::time_point now){
  if(!transient(code))return false;
  begin(now);
  ++attempt_;return canAttempt(now+delay());
 }
 void succeeded(){active_=false;attempt_=0;}
 std::chrono::milliseconds delay()const{return std::chrono::milliseconds(250u<<std::min(attempt_,3u));}
private:
 bool active_=false;unsigned attempt_=0;Clock::time_point started_{};
};
}
