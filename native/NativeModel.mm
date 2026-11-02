#include "NativeSDKDynamic.hpp"
#include <vector>
#include <set>
#include <cmath>
#include <algorithm>

namespace {
constexpr size_t kVertices = 250000, kTriangles = 500000, kNodes = 150000;
struct ModelOwner { SUModelRef value = SU_INVALID; ~ModelOwner(){ if(value.ptr) SUCALL(SUModelRelease,&value); } };
struct MeshOwner { SUMeshHelperRef value = SU_INVALID; ~MeshOwner(){ if(value.ptr) SUCALL(SUMeshHelperRelease,&value); } };
struct StringOwner { SUStringRef value = SU_INVALID; StringOwner(){SKCheck(SUCALL(SUStringCreate,&value),"Create string");} ~StringOwner(){ SUCALL(SUStringRelease,&value); } };
NSString* stringValue(SUStringRef value) {
  size_t length=0, actual=0;
  SKCheck(SUCALL(SUStringGetUTF8Length,value,&length),"Read name size");
  if(length>65536) throw std::runtime_error("SketchUp name is too long");
  std::vector<char> bytes(length+1);
  SKCheck(SUCALL(SUStringGetUTF8,value,bytes.size(),bytes.data(),&actual),"Read name");
  NSString* result=[[NSString alloc] initWithBytes:bytes.data() length:actual encoding:NSUTF8StringEncoding];
  return result.length ? SKNamePrefix(result) : @"SketchUp geometry";
}
struct Matrix {
 double a[16];
 static Matrix identity(){ Matrix m={}; for(int i=0;i<4;i++) m.a[i*5]=1; return m; }
 Matrix times(const SUTransformation& right) const {
  Matrix r={}; for(int c=0;c<4;c++) for(int row=0;row<4;row++) for(int k=0;k<4;k++) r.a[c*4+row]+=a[k*4+row]*right.values[c*4+k];
  for(double x:r.a) if(!std::isfinite(x)) throw std::runtime_error("Invalid SketchUp transform");
  return r;
 }
 SUPoint3D point(SUPoint3D p) const {
  double w=a[3]*p.x+a[7]*p.y+a[11]*p.z+a[15];
  if(!std::isfinite(w)||fabs(w)<1e-12) throw std::runtime_error("Invalid SketchUp homogeneous transform");
  SUPoint3D r={(a[0]*p.x+a[4]*p.y+a[8]*p.z+a[12])/w,(a[1]*p.x+a[5]*p.y+a[9]*p.z+a[13])/w,(a[2]*p.x+a[6]*p.y+a[10]*p.z+a[14])/w};
  if(!std::isfinite(r.x)||!std::isfinite(r.y)||!std::isfinite(r.z)) throw std::runtime_error("Non-finite SketchUp vertex");
  return r;
 }
 bool mirrored()const {return a[0]*(a[5]*a[10]-a[9]*a[6])-a[4]*(a[1]*a[10]-a[9]*a[2])+a[8]*(a[1]*a[6]-a[5]*a[2])<0;}
};
NSDictionary* vec(SUPoint3D p){return @{ @"x":@(p.x*.0254),@"y":@(p.z*.0254),@"z":@(-p.y*.0254) };}
SUPoint3D point(NSDictionary* p){
 SUPoint3D r={[p[@"x"] doubleValue]/.0254,-[p[@"z"] doubleValue]/.0254,[p[@"y"] doubleValue]/.0254};
 if(!std::isfinite(r.x)||!std::isfinite(r.y)||!std::isfinite(r.z)) throw std::runtime_error("Invalid export coordinates"); return r;
}
NSString* materialKey(SUMaterialRef m){return [NSString stringWithFormat:@"%p",m.ptr];}
struct Reader {
 NSString* assets;
 NSMutableArray* entities=[NSMutableArray array];
 NSMutableDictionary* materials=[NSMutableDictionary dictionary];
 std::set<void*> stack;
 size_t vertices=0, triangles=0, nodes=0;
 NSDictionary* material(SUMaterialRef m){
  if(!m.ptr) return @{ @"name":@"Default",@"colorHex":@"#E7DCC8",@"textureScale":@1,@"textureRotation":@0,@"faceOverrides":@[] };
  NSString* key=materialKey(m); NSDictionary* cached=materials[key]; if(cached) return cached;
  NSMutableDictionary* result=[SKReadMaterial(m,assets) mutableCopy]; result[@"textureScale"]=@1;result[@"textureRotation"]=@0;
  materials[key]=result;return result;
 }
 NSMutableDictionary* bucket(NSMutableDictionary* buckets,SUMaterialRef mat,NSString* name){
  NSString* key=materialKey(mat); NSMutableDictionary* b=buckets[key]; if(b)return b;
  NSDictionary* surface=material(mat);
  b=[@{ @"id":NSUUID.UUID.UUIDString,@"name":name,@"kind":@"mesh",@"origin":@{@"x":@0,@"y":@0,@"z":@0},@"width":@0,@"depth":@0,@"height":@0,@"rotation":@0,@"colorHex":surface[@"colorHex"],@"surface":surface,
       @"mesh":[@{@"vertices":[NSMutableArray array],@"triangles":[NSMutableArray array],@"lineIndices":[NSMutableArray array],@"textureCoordinates":[NSMutableArray array]} mutableCopy] } mutableCopy];
  buckets[key]=b;return b;
 }
 void walk(SUEntitiesRef source,const Matrix& transform,SUMaterialRef inherited,NSString* name,size_t depth){
  if(depth>64||++nodes>kNodes||stack.count(source.ptr)) throw std::runtime_error("SketchUp hierarchy is recursive or exceeds limits");
  stack.insert(source.ptr);
  NSMutableDictionary* buckets=[NSMutableDictionary dictionary];
  size_t count=0,actual=0;
  SKCheck(SUCALL(SUEntitiesGetNumFaces,source,&count),"Count faces");
  if(count>kTriangles) throw std::runtime_error("SketchUp face count exceeds limit");
  std::vector<SUFaceRef> faces(count);
  if(count) SKCheck(SUCALL(SUEntitiesGetFaces,source,count,faces.data(),&actual),"Read faces");
  for(size_t f=0;f<actual;f++){
   MeshOwner mesh;SKCheck(SUCALL(SUMeshHelperCreate,&mesh.value,faces[f]),"Triangulate face");
   size_t nv=0,nt=0,n=0; SKCheck(SUCALL(SUMeshHelperGetNumVertices,mesh.value,&nv),"Count face vertices");SKCheck(SUCALL(SUMeshHelperGetNumTriangles,mesh.value,&nt),"Count face triangles");
   if(!nt)continue;
   if(nv>kVertices||nt>kTriangles||vertices+nv>kVertices||triangles+nt>kTriangles) throw std::runtime_error("SketchUp geometry exceeds import limits");
   vertices+=nv;triangles+=nt;
   std::vector<SUPoint3D> positions(nv),uv(nv);std::vector<size_t> indices(nt*3);
   SKCheck(SUCALL(SUMeshHelperGetVertices,mesh.value,nv,positions.data(),&n),"Read face positions");if(n!=nv)throw std::runtime_error("Incomplete face vertices");
   SKCheck(SUCALL(SUMeshHelperGetVertexIndices,mesh.value,indices.size(),indices.data(),&n),"Read face indices");if(n!=indices.size())throw std::runtime_error("Incomplete face indices");
   SUMaterialRef mat=SU_INVALID;SUResult mr=SUCALL(SUFaceGetFrontMaterial,faces[f],&mat);
   if(mr!=SU_ERROR_NONE&&mr!=SU_ERROR_NO_DATA)SKCheck(mr,"Read face material");
   bool inheritedMaterial=!mat.ptr;if(inheritedMaterial)mat=inherited;
   NSMutableDictionary* b=bucket(buckets,mat,name);NSMutableDictionary* out=b[@"mesh"];NSMutableArray* verts=out[@"vertices"],*uvs=out[@"textureCoordinates"],*tris=out[@"triangles"];
   bool textured=[b[@"surface"] objectForKey:@"textureData"]!=nil;
   double s=1,t=1;
   if(textured){SKCheck(SUCALL(SUMeshHelperGetFrontSTQCoords,mesh.value,nv,uv.data(),&n),"Read face UV");if(n!=nv)throw std::runtime_error("Incomplete face UVs");
    // Ordinary vertex UVs interpolate affinely across each triangle. Dividing
    // nonconstant native Q at the corners loses the rational mapping between
    // those corners, so reject it instead of silently warping the texture.
    for(size_t i=0;i<nv;i++){
     double q=uv[i].z,reference=uv[0].z;
     if(!std::isfinite(q)||fabs(q)<1e-12)throw std::runtime_error("Invalid projected texture coordinates");
     if(fabs(q-reference)>std::max(fabs(q),fabs(reference))*1e-9)throw std::runtime_error("SketchUp projective texture mapping cannot be preserved; bake the mapping before importing");
    }
    if(inheritedMaterial){SUTextureRef tex=SU_INVALID;SKCheck(SUCALL(SUMaterialGetTexture,mat,&tex),"Get inherited texture");size_t w=0,h=0;SKCheck(SUCALL(SUTextureGetDimensions,tex,&w,&h,&s,&t),"Read inherited texture scale");}
   }
   NSUInteger base=verts.count;
   for(size_t i=0;i<nv;i++){
    [verts addObject:vec(transform.point(positions[i]))];double u=0,v=0;
    if(textured){if(!std::isfinite(uv[i].z)||fabs(uv[i].z)<1e-12)throw std::runtime_error("Invalid projected texture coordinates");u=uv[i].x/uv[i].z*s;v=1-uv[i].y/uv[i].z*t;if(!std::isfinite(u)||!std::isfinite(v))throw std::runtime_error("Invalid face UV");}
    [uvs addObject:@{@"u":@(u),@"v":@(v)}];
   }
   for(size_t i=0;i<indices.size();i+=3){size_t order[3]={indices[i],indices[i+1],indices[i+2]};if(transform.mirrored())std::swap(order[1],order[2]);for(size_t index:order){if(index>=nv)throw std::runtime_error("Invalid face vertex index");[tris addObject:@(base+index)];}}
  }
  SKCheck(SUCALL(SUEntitiesGetNumEdges,source,false,&count),"Count edges");if(count>1000000)throw std::runtime_error("SketchUp edge count exceeds limit");
  std::vector<SUEdgeRef> edges(count);actual=0;if(count)SKCheck(SUCALL(SUEntitiesGetEdges,source,false,count,edges.data(),&actual),"Read edges");
  for(size_t i=0;i<actual;i++){size_t nf=0;SKCheck(SUCALL(SUEdgeGetNumFaces,edges[i],&nf),"Read edge faces");if(nf)continue;
   if(vertices+2>kVertices)throw std::runtime_error("SketchUp edge geometry exceeds limit");vertices+=2;
   SUMaterialRef edgeMaterial=SU_INVALID;SUResult em=SUCALL(SUDrawingElementGetMaterial,SUCALL(SUEdgeToDrawingElement,edges[i]),&edgeMaterial);if(em!=SU_ERROR_NONE&&em!=SU_ERROR_NO_DATA)SKCheck(em,"Read edge material");if(!edgeMaterial.ptr)edgeMaterial=inherited;
   NSMutableDictionary* b=bucket(buckets,edgeMaterial,name);NSMutableDictionary* out=b[@"mesh"];NSMutableArray* verts=out[@"vertices"],*lines=out[@"lineIndices"],*uvs=out[@"textureCoordinates"];
   SUVertexRef v1=SU_INVALID,v2=SU_INVALID;SUPoint3D p1,p2;SKCheck(SUCALL(SUEdgeGetStartVertex,edges[i],&v1),"Read edge start");SKCheck(SUCALL(SUEdgeGetEndVertex,edges[i],&v2),"Read edge end");SKCheck(SUCALL(SUVertexGetPosition,v1,&p1),"Read edge vertex");SKCheck(SUCALL(SUVertexGetPosition,v2,&p2),"Read edge vertex");
   [lines addObject:@(verts.count)];[verts addObject:vec(transform.point(p1))];[uvs addObject:@{@"u":@0,@"v":@0}];[lines addObject:@(verts.count)];[verts addObject:vec(transform.point(p2))];[uvs addObject:@{@"u":@0,@"v":@0}];
  }
  for(NSString* key in [[buckets allKeys] sortedArrayUsingSelector:@selector(compare:)]){
   NSMutableDictionary* b=buckets[key];NSArray* positions=b[@"mesh"][@"vertices"];
   double low[3]={INFINITY,INFINITY,INFINITY},high[3]={-INFINITY,-INFINITY,-INFINITY};
   for(NSDictionary* v in positions){double xyz[3]={[v[@"x"] doubleValue],[v[@"y"] doubleValue],[v[@"z"] doubleValue]};for(int j=0;j<3;j++){low[j]=std::min(low[j],xyz[j]);high[j]=std::max(high[j],xyz[j]);}}
   b[@"width"]=@(high[0]-low[0]);b[@"height"]=@(high[1]-low[1]);b[@"depth"]=@(high[2]-low[2]);
   [entities addObject:b];if(entities.count>50000)throw std::runtime_error("Too many SketchUp objects");
  }
  SKCheck(SUCALL(SUEntitiesGetNumGroups,source,&count),"Count groups");if(count>kNodes)throw std::runtime_error("Too many groups");std::vector<SUGroupRef> groups(count);actual=0;if(count)SKCheck(SUCALL(SUEntitiesGetGroups,source,count,groups.data(),&actual),"Read groups");
  for(size_t i=0;i<actual;i++){SUTransformation tr;SUEntitiesRef child=SU_INVALID;SKCheck(SUCALL(SUGroupGetTransform,groups[i],&tr),"Read group transform");SKCheck(SUCALL(SUGroupGetEntities,groups[i],&child),"Read group contents");SUMaterialRef mat=SU_INVALID;SUResult r=SUCALL(SUDrawingElementGetMaterial,SUCALL(SUGroupToDrawingElement,groups[i]),&mat);if(r!=SU_ERROR_NONE&&r!=SU_ERROR_NO_DATA)SKCheck(r,"Read group material");if(!mat.ptr)mat=inherited;StringOwner str;SKCheck(SUCALL(SUGroupGetName,groups[i],&str.value),"Read group name");walk(child,transform.times(tr),mat,stringValue(str.value),depth+1);}
  SKCheck(SUCALL(SUEntitiesGetNumInstances,source,&count),"Count components");if(count>kNodes)throw std::runtime_error("Too many components");std::vector<SUComponentInstanceRef> instances(count);actual=0;if(count)SKCheck(SUCALL(SUEntitiesGetInstances,source,count,instances.data(),&actual),"Read components");
  for(size_t i=0;i<actual;i++){SUTransformation tr;SUComponentDefinitionRef def=SU_INVALID;SUEntitiesRef child=SU_INVALID;SKCheck(SUCALL(SUComponentInstanceGetTransform,instances[i],&tr),"Read component transform");SKCheck(SUCALL(SUComponentInstanceGetDefinition,instances[i],&def),"Read component definition");SKCheck(SUCALL(SUComponentDefinitionGetEntities,def,&child),"Read component contents");SUMaterialRef mat=SU_INVALID;SUResult r=SUCALL(SUDrawingElementGetMaterial,SUCALL(SUComponentInstanceToDrawingElement,instances[i]),&mat);if(r!=SU_ERROR_NONE&&r!=SU_ERROR_NO_DATA)SKCheck(r,"Read component material");if(!mat.ptr)mat=inherited;StringOwner str;SKCheck(SUCALL(SUComponentInstanceGetName,instances[i],&str.value),"Read component name");walk(child,transform.times(tr),mat,stringValue(str.value),depth+1);}
  stack.erase(source.ptr);
 }
};
}

NSDictionary* SKReadModel(NSString* path,NSString* assets){
 ModelOwner model;
 if(dlsym(gSDK,"SUModelCreateFromFileWithStatus")){SUModelLoadStatus status;SKCheck(SUCALL(SUModelCreateFromFileWithStatus,&model.value,path.fileSystemRepresentation,&status),"Open SketchUp model");if(status!=SUModelLoadStatus_Success)throw std::runtime_error("SketchUp file is newer than the installed SDK; update the SDK to avoid data loss");}
 else SKCheck(SUCALL(SUModelCreateFromFile,&model.value,path.fileSystemRepresentation),"Open SketchUp model");
 SUEntitiesRef root=SU_INVALID;SKCheck(SUCALL(SUModelGetEntities,model.value,&root),"Read model contents");Reader reader;reader.assets=assets;SUMaterialRef empty=SU_INVALID;reader.walk(root,Matrix::identity(),empty,@"SketchUp geometry",0);
 StringOwner str;SKCheck(SUCALL(SUModelGetName,model.value,&str.value),"Read model name");return @{@"name":stringValue(str.value),@"entities":reader.entities};
}

void SKWriteModel(NSDictionary* document,NSString* path,NSString* assets,int version){
 ModelOwner model;SKCheck(SUCALL(SUModelCreate,&model.value),"Create SketchUp model");SKCheck(SUCALL(SUModelSetName,model.value,[document[@"name"] UTF8String]),"Set model name");SUEntitiesRef root=SU_INVALID;SKCheck(SUCALL(SUModelGetEntities,model.value,&root),"Get model contents");
 NSArray* entities=document[@"entities"];if(entities.count>50000)throw std::runtime_error("Too many export objects");size_t total=0;
 for(NSDictionary* e in entities){NSDictionary* mesh=e[@"mesh"];NSArray* vertices=mesh[@"vertices"],*triangles=mesh[@"triangles"],*lines=mesh[@"lineIndices"],*uv=mesh[@"textureCoordinates"];
  if(!mesh||vertices.count>kVertices||triangles.count%3||lines.count%2||triangles.count/3>kTriangles||(total+=vertices.count)>kVertices)throw std::runtime_error("Invalid or oversized native export mesh");
  std::vector<SUPoint3D> points;for(NSDictionary* v in vertices)points.push_back(point(v));
  SUGroupRef group=SU_INVALID;SKCheck(SUCALL(SUGroupCreate,&group),"Create group");SKCheck(SUCALL(SUEntitiesAddGroup,root,group),"Add group");SKCheck(SUCALL(SUGroupSetName,group,[e[@"name"] UTF8String]),"Set group name");SUEntitiesRef target=SU_INVALID;SKCheck(SUCALL(SUGroupGetEntities,group,&target),"Get group contents");
  NSDictionary* surface=e[@"surface"]?:@{@"name":@"Color",@"colorHex":e[@"colorHex"]?:@"#E7DCC8",@"textureScale":@1,@"textureRotation":@0};SUMaterialRef mat=SKCreateMaterial(surface,model.value,assets);
  SKCheck(SUCALL(SUDrawingElementSetMaterial,SUCALL(SUGroupToDrawingElement,group),mat),"Set group material");
  bool textured=surface[@"textureData"]!=nil;
  SUMaterialRef lineMaterial=mat;
  if(textured&&lines.count){
   // Texture materials have no reliable SketchUp edge color. Keep the editor's
   // line fallback color in a distinct opaque material instead of tinting it.
   NSDictionary* lineSurface=@{@"name":SKNamePrefix([surface[@"name"] stringByAppendingString:@" lines"]),@"colorHex":surface[@"colorHex"]?:@"#E7DCC8",@"textureScale":@1,@"textureRotation":@0};
   lineMaterial=SKCreateMaterial(lineSurface,model.value,assets);
  }
  if(textured&&uv.count!=vertices.count)throw std::runtime_error("Textured native export needs vertex UV coordinates");
  for(NSUInteger i=0;i<triangles.count;i+=3){SUPoint3D facePoints[3];NSUInteger inds[3];for(int j=0;j<3;j++){inds[j]=[triangles[i+j] unsignedIntegerValue];if(inds[j]>=points.size())throw std::runtime_error("Export face index is invalid");facePoints[j]=points[inds[j]];}
   SUFaceRef face=SU_INVALID;SKCheck(SUCALL(SUFaceCreateSimple,&face,facePoints,3),"Create face");SKCheck(SUCALL(SUEntitiesAddFaces,target,1,&face),"Add face");SKCheck(SUCALL(SUFaceSetFrontMaterial,face,mat),"Set face material");SKCheck(SUCALL(SUFaceSetBackMaterial,face,mat),"Set back face material");
   if(textured){SUMaterialPositionInput mapping={};mapping.num_uv_coords=3;mapping.material=mat;for(int j=0;j<3;j++){mapping.points[j]=facePoints[j];NSDictionary* coord=uv[inds[j]];mapping.uv_coords[j]={[coord[@"u"] doubleValue],1-[coord[@"v"] doubleValue]};}SKCheck(SUCALL(SUFacePositionMaterial,face,true,&mapping),"Position face texture");SKCheck(SUCALL(SUFacePositionMaterial,face,false,&mapping),"Position back face texture");}
  }
  for(NSUInteger i=0;i<lines.count;i+=2){NSUInteger a=[lines[i] unsignedIntegerValue],b=[lines[i+1] unsignedIntegerValue];if(a>=points.size()||b>=points.size())throw std::runtime_error("Export line index is invalid");SUEdgeRef edge=SU_INVALID;SKCheck(SUCALL(SUEdgeCreate,&edge,&points[a],&points[b]),"Create edge");SKCheck(SUCALL(SUEntitiesAddEdges,target,1,&edge),"Add edge");SKCheck(SUCALL(SUDrawingElementSetMaterial,SUCALL(SUEdgeToDrawingElement,edge),lineMaterial),"Set edge material");}
 }
 SKCheck(SUCALL(SUModelSaveToFileWithVersion,model.value,path.fileSystemRepresentation,(SUModelVersion)version),"Save SketchUp model");
}
