# frozen_string_literal: true
# Garden Studio Bridge: load this file INSIDE SketchUp Make 2017 or newer.
# Original implementation; no vendor libraries are included.
require 'sketchup.rb'
require 'json'
require 'securerandom'

module GardenStudioBridge
  INCHES_PER_METER = 1.0 / 0.0254
  MAX_FILE_BYTES = 16 * 1024 * 1024

  def self.to_native_point(point)
    result = [Float(point.fetch('x')) * INCHES_PER_METER,
              -Float(point.fetch('z')) * INCHES_PER_METER,
              Float(point.fetch('y')) * INCHES_PER_METER]
    raise 'Coordinates must be finite' unless result.all?(&:finite?)
    result
  end

  def self.from_native_point(point)
    { 'x' => point.x.to_f * 0.0254, 'y' => point.z.to_f * 0.0254, 'z' => -point.y.to_f * 0.0254 }
  end

  def self.transform_local(point, entity)
    origin = entity.fetch('origin'); rotation = Float(entity.fetch('rotation', 0))
    cosine = Math.cos(rotation); sine = Math.sin(rotation)
    x, y, z = point
    to_native_point('x' => Float(origin['x']) + cosine*x + sine*z,
                'y' => Float(origin['y']) + y,
                'z' => Float(origin['z']) - sine*x + cosine*z)
  end

  def self.entity_geometry(entity)
    if entity['kind'] == 'mesh'
      mesh = entity.fetch('mesh')
      points = mesh.fetch('vertices').map { |p| [Float(p['x']), Float(p['y']), Float(p['z'])] }
      triangles = mesh.fetch('triangles', [])
      lines = mesh.fetch('lineIndices', [])
      raise 'Mesh exceeds bridge limits' if points.length > 250_000 || triangles.length > 1_500_000 || lines.length > 1_000_000
      raise 'Malformed mesh indices' unless triangles.length % 3 == 0 && lines.length % 2 == 0 && (triangles + lines).all? { |i| i.is_a?(Integer) && i >= 0 && i < points.length }
      return [points, triangles.each_slice(3).to_a, lines.each_slice(2).to_a]
    end
    w = Float(entity.fetch('width')); d = Float(entity.fetch('depth')); h = Float(entity.fetch('height'))
    if entity['kind'] == 'line'
      return [[[0,0,0], [w,h,d]], [], [[0,1]]]
    end
    raise 'Unsupported geometry kind' unless ['rectangle', 'circle'].include?(entity['kind'])
    base = if entity['kind'] == 'rectangle'
             [[-w/2,0,-d/2],[w/2,0,-d/2],[w/2,0,d/2],[-w/2,0,d/2]]
           else
             (0...32).map { |i| a = i*Math::PI*2/32; [Math.cos(a)*w/2,0,Math.sin(a)*d/2] }
           end
    count = base.length
    if h > 0
      points = base + base.map { |x,y,z| [x,h,z] }
      faces = [(0...count).to_a, (count...(count*2)).to_a.reverse]
      count.times { |i| j=(i+1)%count; faces << [i,i+count,j+count,j] }
      [points, faces, []]
    else
      [base, [(0...count).to_a.reverse], []]
    end
  end

  def self.material_for(model, hex)
    raise 'Color must use #RRGGBB' unless hex =~ /\A#[0-9a-fA-F]{6}\z/
    name = "Garden Studio #{hex}"
    material = model.materials[name] || model.materials.add(name)
    material.color = Sketchup::Color.new(hex[1,2].to_i(16), hex[3,2].to_i(16), hex[5,2].to_i(16))
    material
  end

  def self.import_json
    path = UI.openpanel('Import Garden Studio JSON', '', 'JSON Files|*.json||')
    return unless path
    raise 'Project exceeds the 16 MB bridge limit' if File.size(path) > MAX_FILE_BYTES
    data = JSON.parse(File.read(path))
    entities = data.fetch('entities')
    raise 'Project exceeds the 50,000 object bridge limit' if entities.length > 50_000
    model = Sketchup.active_model
    model.start_operation('Import Garden Studio JSON', true)
    begin
      root = model.entities.add_group
      root.name = data.fetch('name', 'Garden Studio import')
      entities.each do |entity|
        group = root.entities.add_group; group.name = entity.fetch('name', 'Object')
        material = material_for(model, entity.fetch('colorHex', '#E7DCC8'))
        group.material = material
        local, faces, lines = entity_geometry(entity)
        points = local.map { |p| transform_local(p, entity) }
        faces.each do |face|
          result = group.entities.add_face(face.map { |i| points.fetch(i) })
          if result
            result.material = material; result.back_material = material
          end
        end
        lines.each { |line| group.entities.add_line(points.fetch(line[0]), points.fetch(line[1])) }
      end
      model.commit_operation
      model.active_view.zoom_extents
      UI.messagebox('Imported. Use SketchUp File > Save As to save a native .skp model.')
    rescue Exception
      model.abort_operation
      raise
    end
  rescue StandardError => error
    UI.messagebox("Garden Studio import failed: #{error.message}")
  end

  def self.hex_for(material)
    return '#E7DCC8' unless material
    c = material.color
    format('#%02X%02X%02X', c.red, c.green, c.blue)
  end

  def self.mesh_record(name, points, triangles, lines, material)
    raise 'Exported mesh exceeds bridge limits' if points.empty? || points.length > 250_000 || triangles.length > 1_500_000 || lines.length > 1_000_000
    converted = points.map { |p| from_native_point(p) }
    xs=converted.map { |p| p['x'] }; ys=converted.map { |p| p['y'] }; zs=converted.map { |p| p['z'] }
    origin={'x'=>(xs.min+xs.max)/2, 'y'=>ys.min, 'z'=>(zs.min+zs.max)/2}
    vertices=converted.map { |p| {'x'=>p['x']-origin['x'], 'y'=>p['y']-origin['y'], 'z'=>p['z']-origin['z']} }
    { 'id'=>SecureRandom.uuid, 'name'=>name, 'kind'=>'mesh', 'origin'=>origin,
      'width'=>xs.max-xs.min, 'depth'=>zs.max-zs.min, 'height'=>ys.max-ys.min,
      'rotation'=>0, 'colorHex'=>hex_for(material), 'mesh'=>{'vertices'=>vertices,'triangles'=>triangles,'lineIndices'=>lines} }
  end

  # Inspect the complete accumulated transform so nested mirrors cancel in pairs.
  # Axis accessors are supported by the SketchUp 2017 Ruby API.
  def self.mirrored_transform?(transform)
    x = transform.xaxis; y = transform.yaxis; z = transform.zaxis
    determinant = x.x*(y.y*z.z-y.z*z.y) - x.y*(y.x*z.z-y.z*z.x) + x.z*(y.x*z.y-y.y*z.x)
    determinant < 0
  end

  def self.walk(entities, transform, name, inherited_material, records, depth=0)
    raise 'Nested geometry exceeds bridge depth limit' if depth > 64
    entities.each do |entity|
      next if entity.respond_to?(:hidden?) && entity.hidden?
      next if entity.respond_to?(:layer) && !entity.layer.visible?
      if entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        children = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
        child_name = entity.name.to_s.empty? ? name : entity.name
        walk(children, transform*entity.transformation, child_name, entity.material || inherited_material, records, depth+1)
      elsif entity.is_a?(Sketchup::Face)
        mesh=entity.mesh(0); points=mesh.points.map { |p| p.transform(transform) }; triangles=[]
        mesh.polygons.each do |polygon|
          indices=polygon.map { |i| i.abs-1 }
          (1...(indices.length-1)).each { |i| triangles += [indices[0],indices[i],indices[i+1]] }
        end
        if mirrored_transform?(transform)
          triangles.each_slice(3).with_index do |face, index|
            triangles[index*3+1] = face[2]; triangles[index*3+2] = face[1]
          end
        end
        records << mesh_record(name, points, triangles, [], entity.material || inherited_material) unless triangles.empty?
      elsif entity.is_a?(Sketchup::Edge) && entity.faces.empty?
        points=[entity.start.position.transform(transform),entity.end.position.transform(transform)]
        records << mesh_record(name, points, [], [0,1], entity.material || inherited_material)
      end
      raise 'Export exceeds the 50,000 object bridge limit' if records.length > 50_000
    end
  end

  def self.export_json
    path = UI.savepanel('Export Garden Studio JSON', '', 'SketchUp model.gardenstudio.json')
    return unless path
    model=Sketchup.active_model; records=[]
    walk(model.entities, Geom::Transformation.new, 'SketchUp geometry', nil, records)
    data=JSON.pretty_generate('name'=>(model.title.empty? ? 'SketchUp model' : model.title), 'entities'=>records)
    raise 'Export exceeds the 16 MB bridge limit' if data.bytesize > MAX_FILE_BYTES
    File.open(path, 'w') { |file| file.write(data) }
    UI.messagebox('Exported. Open the JSON project in Garden Studio. Geometry and colors transfer; component links, textures and scenes do not.')
  rescue StandardError => error
    UI.messagebox("Garden Studio export failed: #{error.message}")
  end

  def self.import_skm
    path=UI.openpanel('Load native SketchUp material', '', 'SKM Files|*.skm||')
    return unless path
    material=Sketchup.active_model.materials.load(path)
    Sketchup.active_model.materials.current=material if material
  rescue StandardError => error
    UI.messagebox("Material import failed: #{error.message}")
  end

  def self.export_skm
    model=Sketchup.active_model
    material=model.materials.current
    return UI.messagebox('Choose a current material in SketchUp Materials first.') unless material
    path=UI.savepanel('Save native SketchUp material', '', "#{material.name.gsub(/[\/\\:]/,'_')}.skm")
    return unless path
    raise 'SketchUp could not save the material' unless material.save_as(path)
  rescue StandardError => error
    UI.messagebox("Material export failed: #{error.message}")
  end

  unless file_loaded?(__FILE__)
    menu=UI.menu('Extensions').add_submenu('Garden Studio Bridge')
    menu.add_item('Import Garden Studio JSON') { import_json }
    menu.add_item('Export Garden Studio JSON') { export_json }
    menu.add_separator
    menu.add_item('Import SketchUp Material (.skm)') { import_skm }
    menu.add_item('Export Current Material (.skm)') { export_skm }
    file_loaded(__FILE__)
  end
end
