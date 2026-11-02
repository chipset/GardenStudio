# Remaining compatible exchange modes

The repeated user request extends existing v0.4, rather than rebuilding completed codecs. Continue validated directional coverage with no new external packages.

New native lanes: USDZ stored/aligned package export; 3MF/AMF mesh exchange; VRML2/WRL and XML X3D static exchange; native 3DS/LWO mesh exchange. Expand optional registered importer discovery and validated exporters where actual sandbox/backend support exists. Preserve existing SketchUp Make/VCarve routes and prior233tests.

Compatibility remains directional and capability-dependent. Native SKP/SKM require existing Make bridge; DWG/CRV and unsupported proprietary CAD/job data cannot be falsely labeled direct support. Optional user priority question is pending; independent public exchange work proceeds.

Shared archive API: AssetArchive withExtracted(url:body:) validates bounded ZIP before extraction and removes temp afterward; writeStored(files:[String:Data],to:URL,alignment:Int=1) creates atomic stored ZIP, traversal/duplicate/symlink/size/CRC guards. USDZ uses64-byte file payload alignment and root layer first. 3MF uses standard OPC members.

New formats API: read(url:metersPerUnit:Double?=nil,zUp:Bool?=nil) throws ModelDocument; write(_:to:) unless specified. Native geometry meters/Y-up; validate all raw indices/counts/transforms and unsupported material/layout features before returning, never partial geometry. Register only validated directions in ExchangeCatalog and wire actual dispatcher/filename choices. Tests first, coordinate own file scopes; no recursive delegation.

Validation: independent/native reading of generated files when available, asymmetric transforms+units, XML/archive safety, materials/UVs within bounds, malformed sibling rejection. Full SwiftPM suite + native catalog check, signed package and accurate matrix before final.
