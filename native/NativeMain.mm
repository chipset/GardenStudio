#import "NativeSDKDynamic.hpp"
void* gSDK = nullptr;
int main(int argc, const char* argv[]) {
 @autoreleasepool {
  try {
   if(argc != 6) throw std::runtime_error("Usage: worker sdk operation input output assets");
   gSDK=dlopen(argv[1], RTLD_NOW|RTLD_LOCAL);
   if(!gSDK) throw std::runtime_error(dlerror());
   SUCALL(SUInitialize);
   NSString*op=@(argv[2]); NSString*input=@(argv[3]); NSString*output=@(argv[4]); NSString*assets=@(argv[5]);
   NSDictionary* result=nil;
   if([op isEqual:@"probe"]) {
    SUModelRef model=SU_INVALID;
    SKCheck(SUCALL(SUModelCreate,&model),"Create model");
    SKCheck(SUCALL(SUModelRelease,&model),"Release model");
    for(const char* symbol : {"SUModelCreateFromFile","SUModelSaveToFileWithVersion","SUModelLoadMaterial","SUMaterialWriteToFile"})
      if(!dlsym(gSDK,symbol)) throw std::runtime_error(std::string("Missing ")+symbol);
    NSString* skp=[assets stringByAppendingPathComponent:@"capability.skp"];
    SKWriteModel(@{@"name":@"Capability",@"entities":@[]},skp,assets,10);
    SKReadModel(skp,assets);
    NSDictionary* paint=@{@"name":@"Capability",@"colorHex":@"#AA3300",@"textureScale":@1,@"textureRotation":@0,@"faceOverrides":@[]};
    NSString* skm=[assets stringByAppendingPathComponent:@"capability.skm"];
    SKWriteMaterialFile(paint,skm,assets);
    NSDictionary* recovered=SKLoadMaterialFile(skm,assets);
    if(![recovered[@"colorHex"] isEqual:@"#AA3300"]) throw std::runtime_error("SKM capability roundtrip failed");
    result=@{@"available":@YES};
   } else if([op isEqual:@"read-skp"]) result=SKReadModel(input,assets);
   else if([op isEqual:@"read-skm"]) result=SKLoadMaterialFile(input,assets);
   else {
    NSError*error=nil;
    NSData*data=[NSData dataWithContentsOfFile:input options:0 error:&error];
    if(!data || data.length>100*1024*1024) throw std::runtime_error("Missing or oversized worker input");
    id object=[NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if(![object isKindOfClass:NSDictionary.class]) throw std::runtime_error("Invalid worker JSON");
    if([op isEqual:@"write-skp"]) SKWriteModel(object,output,assets,10);
    else if([op isEqual:@"write-skm"]) SKWriteMaterialFile(object,output,assets);
    else throw std::runtime_error("Unknown worker operation");
   }
   if(result) {
    NSError*error=nil; NSData*data=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:&error];
    if(!data || ![data writeToFile:output options:NSDataWritingAtomic error:&error]) throw std::runtime_error("Cannot write worker JSON");
   }
   SUCALL(SUTerminate);
   return 0;
  } catch(const std::exception&error) { fprintf(stderr,"%s\n",error.what()); return 1; }
 }
}
