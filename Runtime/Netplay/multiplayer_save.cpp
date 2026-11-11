// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#include "multiplayer_save.h"
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
namespace emu {
namespace {
struct FD {int value=-1;~FD(){if(value>=0)close(value);}};
void fail(const char *operation){throw std::runtime_error(std::string("Multiplayer save ")+operation+" failed");}
}
Bytes readMultiplayerSave(const std::string &path){
 FD file{open(path.c_str(),O_RDONLY|O_NOFOLLOW|O_CLOEXEC)};if(file.value<0)fail("read");
 struct stat st{};if(fstat(file.value,&st) || !S_ISREG(st.st_mode) || st.st_size<=0 || uint64_t(st.st_size)>SaveJournal::MaxBytes)fail("size check");
 Bytes bytes(size_t(st.st_size));size_t offset=0;
 while(offset<bytes.size()){ssize_t n=read(file.value,bytes.data()+offset,bytes.size()-offset);if(n<0 && errno==EINTR)continue;if(n<=0)fail("read");offset+=size_t(n);}
 uint8_t extra;ssize_t n;do{n=read(file.value,&extra,1);}while(n<0 && errno==EINTR);if(n!=0)fail("concurrent change check");return bytes;
}
void writeMultiplayerSave(const std::string &path,const Bytes &bytes){
 if(path.empty() || bytes.empty() || bytes.size()>SaveJournal::MaxBytes)fail("write bounds");
 std::string pattern=path+".tmp.XXXXXX";std::vector<char> name(pattern.begin(),pattern.end());name.push_back(0);
 FD file{mkstemp(name.data())};if(file.value<0)fail("temporary file creation");
 try{
  if(fchmod(file.value,0600))fail("permissions");size_t offset=0;
  while(offset<bytes.size()){ssize_t n=write(file.value,bytes.data()+offset,bytes.size()-offset);if(n<0 && errno==EINTR)continue;if(n<=0)fail("write");offset+=size_t(n);}
  if(fsync(file.value))fail("flush");if(rename(name.data(),path.c_str()))fail("replace");
 }catch(...){unlink(name.data());throw;}
}
SaveWriter::SaveWriter(std::string path):path_(std::move(path)),worker_([this]{
 std::unique_lock<std::mutex> lock(mutex_);
 while(true){
  wake_.wait(lock,[this]{return stopping_ || bool(latest_);});
  if(!latest_ && stopping_)break;
  auto journal=std::move(latest_);busy_=true;lock.unlock();std::string failure;
  try{writeMultiplayerSave(path_,journal->encode());completed_.store(journal->frames());}
  catch(const std::exception &e){failure=e.what();}
  lock.lock();error_=std::move(failure);busy_=false;wake_.notify_all();
 }
}){}
SaveWriter::~SaveWriter(){{std::lock_guard<std::mutex> lock(mutex_);stopping_=true;}wake_.notify_one();if(worker_.joinable())worker_.join();}
void SaveWriter::submit(const SaveJournal &journal){auto copy=std::make_unique<SaveJournal>(journal);{std::lock_guard<std::mutex> lock(mutex_);if(stopping_)throw std::runtime_error("Saved-game writer stopped");latest_=std::move(copy);}wake_.notify_one();}
void SaveWriter::flush(){std::unique_lock<std::mutex> lock(mutex_);wake_.wait(lock,[this]{return !latest_ && !busy_;});}
std::string SaveWriter::error(){std::lock_guard<std::mutex> lock(mutex_);return error_;}

}
