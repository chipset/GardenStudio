import XCTest
import SketchCore
@testable import SketchIO

final class ModelScriptBridgeTests: XCTestCase {
    func withScript(_ text: String, _ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("example.rb")
        try text.write(to: url, atomically: true, encoding: .utf8)
        try body(url)
    }
    func testRubyRectanglePushPullUsesInchesAndYUp() throws {
        try withScript("face = Sketchup.active_model.entities.add_face([[0,0,0],[10,0,0],[10,20,0],[0,20,0]])\nface.pushpull(30)\n") { url in
            let result = try ModelScriptBridge.runRubyScript(at: url, document: ModelDocument())
            try result.validate()
            let entity = try XCTUnwrap(result.entities.first)
            XCTAssertEqual(result.entities.count, 1)
            XCTAssertEqual(entity.kind, .mesh)
            XCTAssertEqual(entity.width, 0.254, accuracy: 1e-8)
            XCTAssertEqual(entity.depth, 0.508, accuracy: 1e-8)
            XCTAssertEqual(entity.height, 0.762, accuracy: 1e-8)
            XCTAssertEqual(entity.mesh?.triangles.count, 36)
        }
    }
    func testRubyPositiveAndNegativePushPullHaveOutwardWinding() throws {
        for distance in [1, -1] {
            try withScript("f=Sketchup.active_model.entities.add_face([[0,0,0],[1,0,0],[1,1,0],[0,1,0]]); f.pushpull(\(distance))") { url in
                let result = try ModelScriptBridge.runRubyScript(at: url, document: ModelDocument())
                let mesh = try XCTUnwrap(result.entities.first?.triangulatedMesh())
                let center = Vec3(0.0127, Double(distance) * 0.0127, -0.0127)
                var volume = 0.0
                for i in stride(from: 0, to: mesh.triangles.count, by: 3) {
                    let a=mesh.vertices[mesh.triangles[i]], b=mesh.vertices[mesh.triangles[i+1]], c=mesh.vertices[mesh.triangles[i+2]]
                    let u=Vec3(b.x-a.x,b.y-a.y,b.z-a.z), v=Vec3(c.x-a.x,c.y-a.y,c.z-a.z)
                    let n=Vec3(u.y*v.z-u.z*v.y,u.z*v.x-u.x*v.z,u.x*v.y-u.y*v.x)
                    XCTAssertGreaterThan(n.x*((a.x+b.x+c.x)/3-center.x)+n.y*((a.y+b.y+c.y)/3-center.y)+n.z*((a.z+b.z+c.z)/3-center.z), 0, "distance \(distance), triangle \(i/3)")
                    volume += (a.x*(b.y*c.z-b.z*c.y)+a.y*(b.z*c.x-b.x*c.z)+a.z*(b.x*c.y-b.y*c.x))/6
                }
                XCTAssertEqual(volume, pow(0.0254,3), accuracy: 1e-12)
            }
        }
    }
    func testRubyRejectsSelfCrossingFaceWithoutChangingInput() throws {
        let initial=ModelDocument.demo
        var current=initial
        try withScript("e=Sketchup.active_model.entities; e.add_line([0,0,0],[1,0,0]); e.add_face((0...5).map { |i| a=i*4*Math::PI/5; [Math.cos(a),Math.sin(a),0] })") { url in
            XCTAssertThrowsError(current = try ModelScriptBridge.runRubyScript(at:url,document:initial)) { error in
                XCTAssertTrue(error.localizedDescription.contains("convex"))
            }
            XCTAssertEqual(current,initial)
        }
    }
    func testBridgeMirroredAndNestedTransformsPreserveOutwardWinding() throws {
        let bridge=try ModelScriptBridge.extensionScriptURL().path
        try withScript("""
        require 'tmpdir'
        module AuditGeometry
          Point=Struct.new(:x,:y,:z) do
            def transform(t); Point.new(x*t.scale,y,z); end
          end
          Axis=Struct.new(:x,:y,:z)
          class Transform
            attr_reader :scale
            def initialize(s); @scale=s; end
            def *(other); Transform.new(@scale*other.scale); end
            def xaxis; Axis.new(@scale,0,0); end
            def yaxis; Axis.new(0,1,0); end
            def zaxis; Axis.new(0,0,1); end
          end
        end
        module Sketchup
          class ComponentInstance; end
          class Edge; end
          class Group
            attr_reader :entities,:transformation
            def initialize(e,s); @entities=e; @transformation=AuditGeometry::Transform.new(s); end
            def material; nil; end
            def name; 'nested'; end
          end
          class Face
            def initialize(p); @points=p; end
            def mesh(_); Struct.new(:points,:polygons).new(@points,[[1,2,3]]); end
            def material; nil; end
          end
        end
        Dir.mktmpdir do |directory|
          File.write(File.join(directory,'sketchup.rb'),'def file_loaded?(_); true; end')
          $LOAD_PATH.unshift(directory)
          load \(String(reflecting: bridge))
          points=[[0,0,0],[1,0,0],[0,1,0],[0,0,1]].map { |p| AuditGeometry::Point.new(*p) }
          faces=[[0,2,1],[0,1,3],[0,3,2],[1,2,3]].map { |f| Sketchup::Face.new(f.map { |i| points[i] }) }
          [[1],[-1],[-1,-1],[-1,1,-1],[-1,-1,-1]].each do |scales|
            tree=faces
            scales.reverse.each { |scale| tree=[Sketchup::Group.new(tree,scale)] }
            records=[]
            SketchMakeBridge.walk(tree,AuditGeometry::Transform.new(1),'Audit',nil,records)
            volume=records.inject(0.0) do |total,e|
              points=e['mesh']['vertices'].map { |v| ['x','y','z'].map { |k| v[k]+e['origin'][k] } }
              a,b,c=e['mesh']['triangles'].map { |i| points[i] }
              total+(a[0]*(b[1]*c[2]-b[2]*c[1])+a[1]*(b[2]*c[0]-b[0]*c[2])+a[2]*(b[0]*c[1]-b[1]*c[0]))/6
            end
            raise "inverted mirrored mesh: #{scales.inspect}, #{volume}" unless (volume-(0.0254**3/6)).abs < 1e-12
          end
        end
        """) { url in
            XCTAssertEqual(try ModelScriptBridge.runRubyScript(at:url,document:ModelDocument()).entities.count,0)
        }
    }
    func testRubyPreservesCurrentDocumentAndAddsGroupLine() throws {
        let initial = ModelDocument.demo
        try withScript("g = Sketchup.active_model.entities.add_group\ng.name = 'New group'\ng.entities.add_line([0,0,0], [10,0,0])\nputs 'debug output'\n") { url in
            let result = try ModelScriptBridge.runRubyScript(at: url, document: initial)
            XCTAssertEqual(Array(result.entities.prefix(initial.entities.count)), initial.entities)
            XCTAssertEqual(result.entities.count, initial.entities.count + 1)
            XCTAssertEqual(result.entities.last?.name, "New group")
        }
    }
    func testRubyScriptFailureIsReported() throws {
        try withScript("raise 'example failure'\n") { url in
            XCTAssertThrowsError(try ModelScriptBridge.runRubyScript(at: url, document: ModelDocument())) { error in
                XCTAssertTrue(error.localizedDescription.contains("example failure"))
            }
        }
    }
    func testRubyTimeoutStopsInfiniteLoop() throws {
        try withScript("loop {}\n") { url in
            let start = Date()
            XCTAssertThrowsError(try ModelScriptBridge.runRubyScript(at: url, document: ModelDocument(), timeout: 0.25))
            XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        }
    }
    func testBridgePrimitiveGeometryAndCoordinateConversion() throws {
        let bridge = try ModelScriptBridge.extensionScriptURL().path
        try withScript("""
        require 'tmpdir'
        Dir.mktmpdir do |directory|
          File.write(File.join(directory, 'sketchup.rb'), 'def file_loaded?(_); true; end')
          $LOAD_PATH.unshift(directory)
          load \(String(reflecting: bridge))
          p = SketchMakeBridge.to_native_point({'x'=>0.254,'y'=>0.762,'z'=>-0.508})
          raise 'axis/units error' unless p.zip([10,20,30]).all? { |a,b| (a-b).abs < 1e-8 }
          box = {'kind'=>'rectangle','width'=>2,'depth'=>3,'height'=>4}
          vertices, faces, lines = SketchMakeBridge.entity_geometry(box)
          raise 'box topology error' unless vertices.length == 8 && faces.length == 6 && lines.empty?
          mesh = {'kind'=>'mesh','mesh'=>{'vertices'=>[{'x'=>0,'y'=>0,'z'=>0}], 'triangles'=>[0,1,2]}}
          begin
            SketchMakeBridge.entity_geometry(mesh)
            raise 'invalid indices were accepted'
          rescue RuntimeError => error
            raise unless error.message == 'Malformed mesh indices'
          end
        end
        """) { url in
            XCTAssertEqual(try ModelScriptBridge.runRubyScript(at: url, document: ModelDocument()).entities.count, 0)
        }
    }
    func testRubyLengthHelpersAndOutputLimit() throws {
        try withScript("Sketchup.active_model.entities.add_line([0,0,0], [1.m,0,0])") { url in
            let result = try ModelScriptBridge.runRubyScript(at: url, document: ModelDocument())
            XCTAssertEqual(try XCTUnwrap(result.entities.first).width, 1, accuracy: 1e-8)
        }
        try withScript("puts 'x' * 300000") { url in
            XCTAssertThrowsError(try ModelScriptBridge.runRubyScript(at: url, document: ModelDocument())) { error in
                XCTAssertTrue(error.localizedDescription.contains("output limit"))
            }
        }
    }
    func testExtensionExportWritesNamedModuleAndMenus() throws {
        try withScript("") { url in
            try ModelScriptBridge.writeExtension(to: url)
            let body = try String(contentsOf: url)
            XCTAssertTrue(body.contains("module SketchMakeBridge"))
            XCTAssertTrue(body.contains("Import Sketch Make JSON"))
            XCTAssertTrue(body.contains("Export Sketch Make JSON"))
            XCTAssertTrue(body.contains(".save_as"))
        }
    }
}
