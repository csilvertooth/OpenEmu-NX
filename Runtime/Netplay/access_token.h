// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#pragma once
#include <chrono>
#include <mutex>
#include <stdexcept>
#include <string>
#include <utility>
namespace emu {
// Refresh runs under one worker-only lock. Concurrent 401s for an old token
// cannot invalidate a newer credential installed by another worker.
class AccessTokenTimeout:public std::runtime_error{public:AccessTokenTimeout():std::runtime_error("Access credential deadline reached"){};};
class AccessToken {
public:
 using Clock=std::chrono::steady_clock;
 template<class Refresh> std::string get(Clock::time_point now,Refresh refresh,const std::string &rejected={},Clock::time_point deadline=Clock::time_point::max()){
  std::unique_lock<std::timed_mutex> lock(mutex_,std::defer_lock);
  if(deadline==Clock::time_point::max())lock.lock();else if(!lock.try_lock_until(deadline))throw AccessTokenTimeout();
  if(deadline!=Clock::time_point::max() && Clock::now()>=deadline)throw AccessTokenTimeout();
  if(!rejected.empty() && token_==rejected){token_.clear();expires_={};}
  if(!token_.empty() && now+std::chrono::seconds(60)<expires_)return token_;
  auto issued=refresh();validate(issued.first,issued.second);
  token_=std::move(issued.first);expires_=now+std::chrono::seconds(issued.second);return token_;
 }
 static void validate(const std::string &token,int lifetime){
  if(lifetime!=600 || token.size()!=43)throw std::runtime_error("Invalid access credential response");
  for(unsigned char c:token)if(!((c>='a' && c<='z') || (c>='A' && c<='Z') || (c>='0' && c<='9') || c=='-' || c=='_'))throw std::runtime_error("Invalid access credential response");
 }
private:
 std::timed_mutex mutex_;std::string token_;Clock::time_point expires_{};
};
}
