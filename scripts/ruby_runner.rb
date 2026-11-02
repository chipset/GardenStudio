# frozen_string_literal: true
# Local trusted-code runner. This is a small creation API, not a SketchUp emulator.
require 'json'
require 'securerandom'

# SketchUp-style length conveniences; values remain inches in the creation API.
class Numeric
  def inch; to_f; end
  alias inches inch
  def feet; to_f * 12.0; end
  alias foot feet
  def mm; to_f / 25.4; end
  def cm; to_f / 2.54; end
  def m; to_f / 0.0254; end
end

module GardenStudio
  class << self
    attr_accessor :document
  end
  SCALE = 0.0254
  def self.point(value)
    value = value.to_a if value.respond_to?(:to_a)
    raise ArgumentError, 'Expected a finite [x,y,z] point in inches' unless value.is_a?(Array) && value.length == 3 && value.all? { |x| x.is_a?(Numeric) && x.finite? }
    value.map(&:to_f)
  end
  def self.to_model(p)
    { 'x' => p[0] * SCALE, 'y' => p[2] * SCALE, 'z' => -p[1] * SCALE }
  end
  def self.mesh_entity(name, points, triangles, lines = [], color = '#E7DCC8')
    raise ArgumentError, 'Geometry exceeds the runner limit' if points.length > 250_000 || triangles.length > 1_500_000
    converted = points.map { |p| to_model(p) }
    xs = converted.map { |p| p['x'] }; ys = converted.map { |p| p['y'] }; zs = converted.map { |p| p['z'] }
    origin = { 'x' => (xs.min + xs.max) / 2, 'y' => ys.min, 'z' => (zs.min + zs.max) / 2 }
    vertices = converted.map { |p| { 'x' => p['x'] - origin['x'], 'y' => p['y'] - origin['y'], 'z' => p['z'] - origin['z'] } }
    { 'id' => SecureRandom.uuid, 'name' => name, 'kind' => 'mesh', 'origin' => origin, 'width' => xs.max - xs.min, 'depth' => zs.max - zs.min, 'height' => ys.max - ys.min, 'rotation' => 0, 'colorHex' => color, 'mesh' => { 'vertices' => vertices, 'triangles' => triangles, 'lineIndices' => lines } }
  end
  class Face
    attr_accessor :material
    def initialize(points)
      @points = points.map { |p| GardenStudio.point(p) }
      @distance = nil; @material = '#E7DCC8'
      raise ArgumentError, 'add_face requires at least three points' if @points.length < 3
      a = @points[1].zip(@points[0]).map { |x,y| x-y }; b = @points[2].zip(@points[0]).map { |x,y| x-y }
      n = [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]
      length = Math.sqrt(n.sum { |v| v*v }); raise ArgumentError, 'Face points must not be collinear' if length < 1e-9
      @normal = n.map { |v| v/length }
      @points.each do |p|
        delta = p.zip(@points[0]).map { |x,y| x-y }
        raise ArgumentError, 'Face points must be coplanar' if delta.zip(@normal).sum { |x,y| x*y }.abs > 1e-6
      end
      # Fan triangulation is valid only for convex polygon input.
      total_turn = 0.0
      turns = @points.each_index.map do |i|
        p = @points[i]; q = @points[(i+1)%@points.length]; r = @points[(i+2)%@points.length]
        u = q.zip(p).map { |x,y| x-y }; v = r.zip(q).map { |x,y| x-y }
        cross = [u[1]*v[2]-u[2]*v[1],u[2]*v[0]-u[0]*v[2],u[0]*v[1]-u[1]*v[0]]
        turn = cross.zip(@normal).sum { |x,y| x*y }
        total_turn += Math.atan2(turn, u.zip(v).sum { |x,y| x*y })
        turn
      end
      # Same-sign local turns alone also admit stars. A convex boundary makes
      # exactly one full turn, so reject self-crossing multiple-winding rings.
      raise ArgumentError, 'This runner supports simple convex faces only' if turns.any? { |v| v < -1e-8 } || (total_turn - 2*Math::PI).abs > 1e-6
    end
    def pushpull(distance, copy = false)
      raise ArgumentError, 'pushpull expects a finite distance in inches' unless distance.is_a?(Numeric) && distance.finite?
      raise ArgumentError, 'copy=true pushpull is not supported' if copy
      @distance = distance.to_f
      self
    end
    def output(name, translation)
      points = @points.map { |p| p.zip(translation).map { |x,y| x+y } }
      count = points.length
      triangles = []
      if @distance && @distance.abs > 1e-9
        points += points.map { |p| p.zip(@normal).map { |x,n| x+n*@distance } }
        (1...(count-1)).each { |i| triangles += [0,i+1,i, count,count+i,count+i+1] }
        count.times do |i|
          j=(i+1)%count
          triangles += [i,j,count+j,i,count+j,count+i]
        end
        triangles = triangles.each_slice(3).map { |a,b,c| [a,c,b] }.flatten if @distance < 0
      else
        (1...(count-1)).each { |i| triangles += [0,i,i+1] }
      end
      GardenStudio.mesh_entity(name, points, triangles, [], @material)
    end
  end
  class Edge
    def initialize(a,b); @points=[GardenStudio.point(a),GardenStudio.point(b)]; end
    def output(name, translation)
      points=@points.map { |p| p.zip(translation).map { |x,y| x+y } }
      raise ArgumentError, 'Line must have nonzero length' if points[0] == points[1]
      GardenStudio.mesh_entity(name, points, [], [0,1], '#353B3C')
    end
  end
  class Group
    attr_accessor :name
    attr_reader :entities
    def initialize; @name='Ruby group'; @entities=Entities.new; @translation=[0,0,0]; end
    def move!(point); @translation=GardenStudio.point(point); self; end
    def output(parent_name, translation)
      @entities.output(@name, @translation.zip(translation).map { |x,y| x+y })
    end
  end
  class Entities
    def initialize; @items=[]; end
    def add_line(a,b); item=Edge.new(a,b); @items << item; item; end
    def add_face(*points)
      points=points.first if points.length == 1 && points.first.is_a?(Array)
      item=Face.new(points); @items << item; item
    end
    def add_group; item=Group.new; @items << item; item; end
    def output(name='Ruby geometry', translation=[0,0,0])
      @items.flat_map { |item| result=item.output(name, translation); result.is_a?(Array) ? result : [result] }
    end
  end
  class Model
    attr_reader :entities
    def initialize; @entities=Entities.new; end
    def start_operation(*args); true; end
    def commit_operation; true; end
  end
end
module Sketchup
  def self.active_model; @model ||= GardenStudio::Model.new; end
end

begin
  input=JSON.parse(STDIN.read)
  raise ArgumentError, 'Expected a model document' unless input.is_a?(Hash) && input['entities'].is_a?(Array) && input['name'].is_a?(String)
  GardenStudio.document=input
  # Keep debug puts away from the JSON response stream.
  $stdout=$stderr
  load File.expand_path(ARGV.fetch(0))
  GardenStudio.document['entities'].concat(Sketchup.active_model.entities.output)
  raise ArgumentError, 'Too many entities' if GardenStudio.document['entities'].length > 50_000
  STDOUT.write(JSON.generate(GardenStudio.document))
rescue Exception => error
  STDERR.write("#{error.class}: #{error.message}\n")
  exit 1
end
