#include "NativeSDKDynamic.hpp"
#import <ImageIO/ImageIO.h>
#include <cmath>
#include <vector>

namespace {
constexpr NSUInteger maximumTexture = 10 * 1024 * 1024;
void invalid(const char* message) { throw std::runtime_error(message); }
NSString* materialName(SUMaterialRef material) {
  SUStringRef value = SU_INVALID;
  SKCheck(SUCALL(SUStringCreate, &value), "Create material name");
  try {
    SKCheck(SUCALL(SUMaterialGetName, material, &value), "Read material name");
    size_t count = 0, copied = 0;
    SKCheck(SUCALL(SUStringGetUTF8Length, value, &count), "Read material name length");
    if (count > 65536) invalid("SketchUp material name is too long.");
    std::vector<char> buffer(count + 1);
    SKCheck(SUCALL(SUStringGetUTF8, value, buffer.size(), buffer.data(), &copied), "Read material name text");
    NSString* result = [NSString stringWithUTF8String:buffer.data()];
    SUCALL(SUStringRelease, &value);
    if (!result.length) return @"Material";
    return SKNamePrefix(result);
  } catch (...) { SUCALL(SUStringRelease, &value); throw; }
}
NSString* validateImage(NSData* data) {
  if (!data || !data.length || data.length > maximumTexture) invalid("SketchUp texture exceeds the 10 MB limit.");
  CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
  if (!source) invalid("SketchUp texture is not a valid PNG or JPEG.");
  NSString* type = (__bridge NSString*)CGImageSourceGetType(source);
  NSDictionary* properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr));
  NSUInteger width = [properties[(__bridge NSString*)kCGImagePropertyPixelWidth] unsignedIntegerValue];
  NSUInteger height = [properties[(__bridge NSString*)kCGImagePropertyPixelHeight] unsignedIntegerValue];
  bool valid = ([type isEqualToString:@"public.png"] || [type isEqualToString:@"public.jpeg"]) && CGImageSourceGetCount(source) == 1 && width && height && width <= 8192 && height <= 8192 && width * height <= 16777216;
  NSString* extension = [type isEqualToString:@"public.png"] ? @"png" : @"jpg";
  CFRelease(source);
  if (!valid) invalid("SketchUp texture must be a PNG/JPEG at most 8192 pixels per side and 16 megapixels.");
  return extension;
}
NSString* temporaryImage(NSString* assets, NSString* extension) {
  return [assets stringByAppendingPathComponent:[NSString stringWithFormat:@"material-%@.%@", NSUUID.UUID.UUIDString, extension]];
}
}

NSDictionary* SKReadMaterial(SUMaterialRef material, NSString* assets) {
  SUMaterialType type;
  SKCheck(SUCALL(SUMaterialGetType, material, &type), "Read material type");
  bool useOpacity = false;
  SKCheck(SUCALL(SUMaterialGetUseOpacity, material, &useOpacity), "Read material opacity usage");
  double alpha = 1;
  if (useOpacity) SKCheck(SUCALL(SUMaterialGetOpacity, material, &alpha), "Read material opacity");
  if (!std::isfinite(alpha) || alpha < .999999) invalid("Transparent SketchUp materials cannot be represented by this app.");
  SUColor color = {231, 220, 200, 255};
  if (type == SUMaterialType_Colored || type == SUMaterialType_ColorizedTexture)
    SKCheck(SUCALL(SUMaterialGetColor, material, &color), "Read material color");
  NSMutableDictionary* result = [@{@"id": NSUUID.UUID.UUIDString, @"name":materialName(material), @"colorHex":[NSString stringWithFormat:@"#%02X%02X%02X",color.red,color.green,color.blue], @"textureScale":@1, @"textureRotation":@0, @"faceOverrides":@[]} mutableCopy];
  if (type != SUMaterialType_Colored) {
    SUTextureRef texture = SU_INVALID;
    SKCheck(SUCALL(SUMaterialGetTexture, material, &texture), "Read material texture");
    size_t width = 0, height = 0; double s = 0, t = 0;
    SKCheck(SUCALL(SUTextureGetDimensions, texture, &width, &height, &s, &t), "Read texture dimensions");
    if (!width || !height || width > 8192 || height > 8192 || width * height > 16777216 || !std::isfinite(s) || !std::isfinite(t) || s <= 0 || t <= 0) invalid("SketchUp texture dimensions are invalid or too large.");
    double scale = .0254 / s;
    if (scale < .0001 || scale > 100000) invalid("SketchUp texture repeat size is outside supported limits.");
    NSString* path = temporaryImage(assets, @"png");
    SKCheck(SUCALL(SUTextureWriteToFile, texture, path.fileSystemRepresentation), "Extract material texture");
    NSDictionary* attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if ([attributes[NSFileSize] unsignedLongLongValue] > maximumTexture) { [NSFileManager.defaultManager removeItemAtPath:path error:nil]; invalid("SketchUp texture exceeds the 10 MB limit."); }
    NSData* data = [NSData dataWithContentsOfFile:path];
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    validateImage(data);
    result[@"textureData"] = [data base64EncodedStringWithOptions:0];
    result[@"textureScale"] = @(scale);
    // Face importers bake actual native STQ into UVs. These extra keys let them
    // compensate unequal physical texture dimensions without losing appearance.
    result[@"nativeTextureSScale"] = @(s);
    result[@"nativeTextureTScale"] = @(t);
  }
  return result;
}

SUMaterialRef SKCreateMaterial(NSDictionary* surface, SUModelRef model, NSString* assets) {
  NSString* name = surface[@"name"] ?: @"Material";
  NSString* hex = surface[@"colorHex"] ?: @"#E7DCC8";
  if (![name isKindOfClass:NSString.class] || !name.length || ![SKNamePrefix(name) isEqualToString:name] || ![hex isKindOfClass:NSString.class] || hex.length != 7 || ![hex hasPrefix:@"#"]) invalid("Invalid SketchUp material name or color.");
  unsigned int rgb = 0; NSScanner* scanner = [NSScanner scannerWithString:[hex substringFromIndex:1]];
  if (![scanner scanHexInt:&rgb] || !scanner.isAtEnd) invalid("Invalid SketchUp material color.");
  double scale = surface[@"textureScale"] ? [surface[@"textureScale"] doubleValue] : 1;
  if (!std::isfinite(scale) || scale < .0001 || scale > 100000) invalid("Invalid SketchUp material repeat size.");
  SUMaterialRef material = SU_INVALID;
  SKCheck(SUCALL(SUMaterialCreate, &material), "Create material");
  bool owned = false;
  try {
    SKCheck(SUCALL(SUMaterialSetName, material, name.UTF8String), "Set material name");
    SUColor color = {static_cast<unsigned char>((rgb >> 16) & 255), static_cast<unsigned char>((rgb >> 8) & 255), static_cast<unsigned char>(rgb & 255), 255};
    SKCheck(SUCALL(SUMaterialSetColor, material, &color), "Set material color");
    if (NSString* encoded = surface[@"textureData"]) {
      if (![encoded isKindOfClass:NSString.class] || encoded.length > maximumTexture * 4 / 3 + 8) invalid("Invalid SketchUp texture data.");
      NSData* data = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
      NSString* extension = validateImage(data);
      NSString* path = temporaryImage(assets, extension);
      if (![data writeToFile:path atomically:YES]) invalid("Could not prepare SketchUp texture.");
      SUTextureRef texture = SU_INVALID;
      SUResult created = SUCALL(SUTextureCreateFromFile, &texture, path.fileSystemRepresentation, scale / .0254, scale / .0254);
      [NSFileManager.defaultManager removeItemAtPath:path error:nil];
      SKCheck(created, "Create material texture");
      SUResult attached = SUCALL(SUMaterialSetTexture, material, texture);
      if (attached != SU_ERROR_NONE) SUCALL(SUTextureRelease, &texture);
      SKCheck(attached, "Attach material texture");
      SKCheck(SUCALL(SUMaterialSetType, material, SUMaterialType_Textured), "Set textured material type");
    }
    SKCheck(SUCALL(SUModelAddMaterials, model, 1, &material), "Add material to model");
    owned = true;
    return material;
  } catch (...) { if (!owned) SUCALL(SUMaterialRelease, &material); throw; }
}

NSDictionary* SKLoadMaterialFile(NSString* path, NSString* assets) {
  SUModelRef model = SU_INVALID;
  SKCheck(SUCALL(SUModelCreate, &model), "Create material container");
  try {
    SUMaterialRef material = SU_INVALID;
    SKCheck(SUCALL(SUModelLoadMaterial, model, path.fileSystemRepresentation, &material), "Load SKM material");
    NSDictionary* result = SKReadMaterial(material, assets);
    if (result[@"textureData"]) {
      double s = [result[@"nativeTextureSScale"] doubleValue], t = [result[@"nativeTextureTScale"] doubleValue];
      if (std::abs(s - t) > 1e-6 * std::max(s,t)) invalid("This SKM uses unequal horizontal and vertical repeat sizes, which this material editor cannot preserve.");
    }
    SUCALL(SUModelRelease, &model);
    return result;
  } catch (...) { SUCALL(SUModelRelease, &model); throw; }
}

void SKWriteMaterialFile(NSDictionary* surface, NSString* path, NSString* assets) {
  if ([surface[@"faceOverrides"] count]) invalid("An SKM file stores one material; clear face overrides before exporting it.");
  if (surface[@"textureData"] && std::abs([surface[@"textureRotation"] doubleValue]) > 1e-10) invalid("SKM stores a material without face texture rotation; set rotation to zero before exporting.");
  SUModelRef model = SU_INVALID;
  SKCheck(SUCALL(SUModelCreate, &model), "Create material container");
  try {
    SUMaterialRef material = SKCreateMaterial(surface, model, assets);
    SKCheck(SUCALL(SUMaterialWriteToFile, material, path.fileSystemRepresentation), "Write SKM material");
    SUCALL(SUModelRelease, &model);
  } catch (...) { SUCALL(SUModelRelease, &model); throw; }
}
