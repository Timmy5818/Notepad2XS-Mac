#pragma once
#include "ExAlgorithms.h"
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>
namespace xs {
inline constexpr std::uint64_t keyFileMinimum=100;
inline constexpr std::uint64_t keyFileLimit=100ULL*1024*1024;
inline bool validKeyFileSize(std::uint64_t n) noexcept {return n>=keyFileMinimum && n<=keyFileLimit;}
// Raw bytes -> standard RFC4648 Base64 (with padding, no whitespace) -> EX_MD3 v6.
class KeyFileInput {
 std::uint64_t expected_,read_=0;
 unsigned char tail_[3]={};unsigned count_=0;
 std::u16string base64_;
 bool finished_=false;
 void emit(unsigned n){
  constexpr char16_t alphabet[]=u"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  unsigned v=(unsigned(tail_[0])<<16)|(unsigned(tail_[1])<<8)|tail_[2];
  base64_+=alphabet[(v>>18)&63];base64_+=alphabet[(v>>12)&63];
  base64_+=n>1?alphabet[(v>>6)&63]:u'=';base64_+=n>2?alphabet[v&63]:u'=';
  tail_[0]=tail_[1]=tail_[2]=0;count_=0;
 }
public:
 explicit KeyFileInput(std::uint64_t n):expected_(n){
  if(!validKeyFileSize(n))throw std::length_error("key file size");
  base64_.reserve(static_cast<std::size_t>(((n+2)/3)*4));
 }
 KeyFileInput(const KeyFileInput&)=delete;
 KeyFileInput& operator=(const KeyFileInput&)=delete;
 ~KeyFileInput(){if(!base64_.empty()){volatile char16_t* p=&base64_[0];for(std::size_t i=0;i<base64_.size();++i)p[i]=0;}for(auto& b:tail_)b=0;}
 void append(const unsigned char* p,std::size_t n){
  if(finished_ || n>expected_-read_)throw std::length_error("key file changed");
  if(n && !p)throw std::invalid_argument("key file input");
  for(std::size_t i=0;i<n;++i){tail_[count_++]=p[i];if(count_==3)emit(3);}
  read_+=n;
 }
 void complete(){
  if(finished_ || read_!=expected_)throw std::length_error("key file incomplete");
  if(count_)emit(count_);
  finished_=true;
 }
 const std::u16string& base64() const {if(!finished_)throw std::logic_error("key file incomplete");return base64_;}
 std::string password(const std::function<void(unsigned)>& progress={})const{return exmd3WithProgress(base64(),progress);}
};
}
