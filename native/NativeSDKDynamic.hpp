#pragma once
#import <Foundation/Foundation.h>
#include <SketchUpAPI/sketchup.h>
#include <dlfcn.h>
#include <stdexcept>
#include <string>
extern void* gSDK;
template<typename F> F skAPI(const char* name) {
  auto p = dlsym(gSDK, name);
  if (!p) throw std::runtime_error(std::string("SketchUp SDK is missing ") + name);
  return reinterpret_cast<F>(p);
}
#define SUCALL(name, ...) skAPI<decltype(&name)>(#name)(__VA_ARGS__)
inline void SKCheck(SUResult result, const char* operation) {
  if (result != SU_ERROR_NONE) throw std::runtime_error(std::string(operation) + " failed (" + std::to_string(result) + ")");
}
// Match the editor's character limits without splitting UTF-16 surrogate pairs
// or composed characters (emoji, combining accents and joined sequences).
inline NSString* SKNamePrefix(NSString* name, NSUInteger maximum = 200) {
  __block NSUInteger count = 0, end = 0;
  [name enumerateSubstringsInRange:NSMakeRange(0, name.length)
                         options:NSStringEnumerationByComposedCharacterSequences | NSStringEnumerationSubstringNotRequired
                      usingBlock:^(NSString*, NSRange range, NSRange, BOOL* stop) {
    if (count++ < maximum) end = NSMaxRange(range); else *stop = YES;
  }];
  return [name substringToIndex:end];
}
NSDictionary* SKReadModel(NSString* path, NSString* assets);
void SKWriteModel(NSDictionary* document, NSString* path, NSString* assets, int version);
NSDictionary* SKReadMaterial(SUMaterialRef material, NSString* assets);
SUMaterialRef SKCreateMaterial(NSDictionary* surface, SUModelRef model, NSString* assets);
NSDictionary* SKLoadMaterialFile(NSString* path, NSString* assets);
void SKWriteMaterialFile(NSDictionary* surface, NSString* path, NSString* assets);
