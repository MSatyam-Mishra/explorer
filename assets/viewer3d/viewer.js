// Offline three.js model viewer for the Explorer app.
//
// Query parameters:
//   src  - URL of the model file (served by the app's loopback server)
//   ext  - lower-case file extension without the dot (glb, obj, stl, ...)
//   name - display name of the file (optional)
//   size - file size in bytes, used for progress (optional)
//   bg   - initial background: dark | light | gradient | transparent
//
// The app may define `window.__viewer3dFiles` (array of paths relative to the
// model's folder) so references with wrong case, backslashes or absolute
// author paths can still be resolved to sibling files.
//
// Events go to Flutter through `window.__v3dPost(type, payload)` (see
// index.html). Commands come in through `window.viewer.command(name, arg)`.

import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';

window.__v3dStarted = true;

const post = (type, payload) => window.__v3dPost(type, payload);

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

const params = new URLSearchParams(location.search);
const SRC = params.get('src') || '';
const EXT = (params.get('ext') || extensionOf(SRC)).toLowerCase().replace(/^\./, '');
const NAME = params.get('name') || safeDecode(SRC.split(/[?#]/)[0].split('/').pop() || 'model');
const SIZE_HINT = Number(params.get('size')) || 0;
const MODEL_BASE = SRC ? new URL('./', new URL(SRC, location.href)).href : location.href;
const LIBS_BASE = new URL('./three/jsm/libs/', location.href).href;

const FORMAT_NAMES = {
  glb: 'glTF Binary', gltf: 'glTF', obj: 'Wavefront OBJ', stl: 'STL', ply: 'PLY',
  fbx: 'Autodesk FBX', dae: 'COLLADA', '3ds': '3D Studio', '3mf': '3MF', amf: 'AMF',
  wrl: 'VRML', vrml: 'VRML', usdz: 'USDZ', usda: 'USD (ASCII)', usdc: 'USD (binary)',
  usd: 'USD', off: 'OFF', xyz: 'XYZ point cloud', pcd: 'PCD point cloud', vtk: 'VTK',
  vtp: 'VTK PolyData', lwo: 'LightWave', md2: 'Quake II MD2', vox: 'MagicaVoxel',
  gcode: 'G-code', gco: 'G-code', drc: 'Draco', kmz: 'KMZ', '3dm': 'Rhino 3DM',
};
const FORMAT = FORMAT_NAMES[EXT] || EXT.toUpperCase();

// Formats that are conventionally authored Z-up and that the loader doesn't convert.
const Z_UP_FORMATS = new Set(['stl', '3mf', 'amf', '3ds']);

class ViewerError extends Error {
  constructor(code, message, detail) {
    super(message);
    this.code = code;
    this.detail = detail;
  }
}

// ---------------------------------------------------------------------------
// Renderer, scene, camera, controls
// ---------------------------------------------------------------------------

const stage = document.getElementById('stage');

let renderer;
try {
  renderer = new THREE.WebGLRenderer({
    antialias: true,
    alpha: true,
    powerPreference: 'high-performance',
  });
} catch (e) {
  window.__v3dFailed = true;
  post('error', {
    code: 'no_webgl',
    message: 'Couldn\'t start 3D graphics (WebGL) on this device.',
    detail: String(e && e.message || e),
  });
  throw e;
}

renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
renderer.setSize(Math.max(1, stage.clientWidth), Math.max(1, stage.clientHeight), false);
renderer.setClearColor(0x000000, 0);
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.NeutralToneMapping;
renderer.toneMappingExposure = 1.0;
stage.appendChild(renderer.domElement);

renderer.domElement.addEventListener('webglcontextlost', (event) => {
  event.preventDefault();
  post('error', {
    code: 'context_lost',
    message: 'The 3D graphics context was lost. The device may be low on graphics memory.',
  });
});

const scene = new THREE.Scene();
const pmrem = new THREE.PMREMGenerator(renderer);
scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;
scene.environmentIntensity = 0.9;
pmrem.dispose();

const camera = new THREE.PerspectiveCamera(45, 1, 0.01, 1000);
scene.add(camera);

const hemiLight = new THREE.HemisphereLight(0xffffff, 0x60646e, 0.8);
scene.add(hemiLight);

// Head light: follows the camera so the visible side is always lit.
const headLight = new THREE.DirectionalLight(0xffffff, 1.4);
headLight.position.set(1, 1.5, 0);
headLight.target.position.set(0, 0, -2);
camera.add(headLight);
camera.add(headLight.target);

const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = true;
controls.dampingFactor = 0.09;
controls.screenSpacePanning = true;
controls.autoRotateSpeed = 2.0;
controls.listenToKeyEvents(window);
controls.addEventListener('change', requestRender);

// Model hierarchy: scene > modelRoot (centering offset) > orient (up axis) > model
const modelRoot = new THREE.Group();
const orient = new THREE.Group();
modelRoot.add(orient);
scene.add(modelRoot);

let model = null;
let gridHelper = null;
let axesHelper = null;
const bounds = { size: new THREE.Vector3(), radius: 1 };
const home = { position: new THREE.Vector3(0, 1, 3), target: new THREE.Vector3() };

const state = {
  autoRotate: false,
  wireframe: false,
  grid: true,
  axes: false,
  background: normalizeBackground(params.get('bg')),
  shading: 'original',
  zUp: Z_UP_FORMATS.has(EXT),
  pointScale: 1,
};

const originalMaterials = new Map(); // Object3D -> Material | Material[]
const flatMaterialCache = new WeakMap();
const normalMaterial = new THREE.MeshNormalMaterial({ side: THREE.DoubleSide });
const warnings = [];
const missingFiles = new Set();
let hasPoints = false;
let hasMeshes = false;
let modelReady = false;

applyBackground();

// ---------------------------------------------------------------------------
// Render loop (renders on demand; continuous only while something moves)
// ---------------------------------------------------------------------------

const clock = new THREE.Clock();
let needsRender = true;
let tween = null;

function requestRender() {
  needsRender = true;
}

renderer.setAnimationLoop(() => {
  const dt = Math.min(clock.getDelta(), 0.1);
  let changed = false;

  if (tween) {
    const k = Math.min(1, (performance.now() - tween.start) / tween.duration);
    const e = 1 - Math.pow(1 - k, 3);
    camera.position.lerpVectors(tween.p0, tween.p1, e);
    controls.target.lerpVectors(tween.t0, tween.t1, e);
    camera.lookAt(controls.target);
    if (k >= 1) {
      tween = null;
      controls.update();
    }
    changed = true;
  } else if (controls.update(dt)) {
    changed = true;
  }

  if (animation.mixer && animation.playing) {
    animation.mixer.update(dt);
    changed = true;
  }

  if (changed || needsRender) {
    needsRender = false;
    renderer.render(scene, camera);
  }
});

new ResizeObserver(() => {
  const w = Math.max(1, stage.clientWidth);
  const h = Math.max(1, stage.clientHeight);
  renderer.setSize(w, h, false);
  camera.aspect = w / h;
  camera.updateProjectionMatrix();
  requestRender();
}).observe(stage);

renderer.domElement.addEventListener('dblclick', () => resetView());

// ---------------------------------------------------------------------------
// Resource resolution (case-insensitive, backslashes, absolute author paths)
// ---------------------------------------------------------------------------

const fileIndex = new Map(); // lower-case relative path -> actual path
const baseIndex = new Map(); // lower-case basename -> shallowest actual path
{
  const files = Array.isArray(window.__viewer3dFiles) ? window.__viewer3dFiles : [];
  const sorted = files
    .filter((f) => typeof f === 'string' && f)
    .sort((a, b) => a.split('/').length - b.split('/').length);
  for (const f of sorted) {
    const lower = f.toLowerCase();
    fileIndex.set(lower, f);
    const base = lower.split('/').pop();
    if (!baseIndex.has(base)) baseIndex.set(base, f);
  }
}

const IMAGE_EXT = /\.(png|jpe?g|gif|webp|bmp|tga|tiff?|psd|dds|exr|hdr|avif)$/i;
const ALT_IMAGE_EXT = ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif', 'tga'];

function lookupFile(path) {
  const segs = [];
  for (const s of path.split('/')) {
    if (!s || s === '.') continue;
    if (s === '..') {
      segs.pop();
      continue;
    }
    segs.push(s);
  }
  if (!segs.length) return null;
  // Longest suffix first: exact relative path, then trailing parts of an
  // absolute author path (C:/work/model/textures/a.png -> textures/a.png).
  for (let k = segs.length; k >= 1; k--) {
    const hit = fileIndex.get(segs.slice(segs.length - k).join('/').toLowerCase());
    if (hit) return hit;
  }
  const base = segs[segs.length - 1].toLowerCase();
  const byName = baseIndex.get(base);
  if (byName) return byName;
  // Same image under another extension (wood.psd -> wood.png).
  if (IMAGE_EXT.test(base)) {
    const stem = base.replace(/\.[^.]+$/, '');
    for (const e of ALT_IMAGE_EXT) {
      const alt = baseIndex.get(`${stem}.${e}`);
      if (alt) return alt;
    }
  }
  return null;
}

function encodePath(path) {
  return path.split('/').map(encodeURIComponent).join('/');
}

function resolveResourceUrl(url) {
  if (!url || url.startsWith('data:') || url.startsWith('blob:')) return url;
  let rel;
  if (url.startsWith(MODEL_BASE)) {
    rel = url.slice(MODEL_BASE.length);
  } else if (/^[a-zA-Z]:[\\/]/.test(url) || url.startsWith('\\\\') || /^file:/i.test(url)) {
    rel = url;
  } else if (url.startsWith('/') && !url.startsWith('//')) {
    rel = url;
  } else {
    return url;
  }
  const path = safeDecode(rel.split(/[?#]/)[0]).replace(/\\/g, '/').replace(/^file:\/*/i, '');
  const hit = lookupFile(path);
  if (hit) return MODEL_BASE + encodePath(hit);
  if (url.startsWith(MODEL_BASE) && rel.includes('\\')) {
    return MODEL_BASE + encodePath(path.replace(/^\/+/, ''));
  }
  return url;
}

function displayNameOf(url) {
  if (!url) return 'unknown file';
  if (url.startsWith('blob:') || url.startsWith('data:')) return 'embedded resource';
  let s = url.startsWith(MODEL_BASE) ? url.slice(MODEL_BASE.length) : url.split('/').pop();
  s = safeDecode(s.split(/[?#]/)[0]).replace(/\\/g, '/');
  return s || url;
}

// ---------------------------------------------------------------------------
// Loading manager (tracks textures/buffers and missing files)
// ---------------------------------------------------------------------------

const manager = new THREE.LoadingManager();
manager.setURLModifier(resolveResourceUrl);
manager.onError = (url) => {
  missingFiles.add(displayNameOf(url));
  scheduleStats();
};
manager.onProgress = (url, loaded, total) => {
  requestRender();
  if (!modelReady) {
    postProgress('resources', total ? loaded / total : null, `Loading resources ${loaded}/${total}`);
  }
};
manager.onLoad = () => {
  requestRender();
  if (modelReady) scheduleStats();
};

// Picks TGALoader or TextureLoader by the *resolved* URL, so a missing
// `wood.tga` that resolves to `wood.png` still decodes.
class SmartTextureLoader extends THREE.Loader {
  constructor(loadingManager, TGALoader) {
    super(loadingManager);
    this.tga = new TGALoader(loadingManager);
    this.image = new THREE.TextureLoader(loadingManager);
  }

  load(url, onLoad, onProgress, onError) {
    let full = url;
    if (this.path && !/^(blob:|data:|[a-z]+:\/\/)/i.test(url)) full = this.path + url;
    const resolved = this.manager.resolveURL(full);
    const isBrowserImage = /\.(png|jpe?g|gif|webp|bmp|avif)$/i.test(resolved.split(/[?#]/)[0]);
    const loader = isBrowserImage ? this.image : this.tga;
    loader.setPath('');
    loader.setCrossOrigin(this.crossOrigin);
    return loader.load(resolved, onLoad, onProgress, onError);
  }
}

async function registerTextureHandlers() {
  const { TGALoader } = await import('three/addons/loaders/TGALoader.js');
  manager.addHandler(/\.tga$/i, new SmartTextureLoader(manager, TGALoader));
}

// ---------------------------------------------------------------------------
// Fetch helpers
// ---------------------------------------------------------------------------

let lastProgressPost = 0;
function postProgress(stage, fraction, label, force = false) {
  const now = performance.now();
  if (!force && now - lastProgressPost < 80) return;
  lastProgressPost = now;
  post('progress', {
    stage,
    fraction: fraction == null || !isFinite(fraction) ? null : Math.max(0, Math.min(1, fraction)),
    label,
  });
}

async function fetchBuffer(url, { progress = false, optional = false } = {}) {
  let res;
  try {
    res = await fetch(url);
  } catch (e) {
    if (optional) return null;
    throw new ViewerError('read_failed', `Couldn't read "${displayNameOf(url)}".`, String(e));
  }
  if (!res.ok) {
    if (optional) return null;
    throw new ViewerError('missing_file', `Missing file "${displayNameOf(url)}".`);
  }
  if (!progress || !res.body || !res.body.getReader) return await res.arrayBuffer();

  const headerTotal = Number(res.headers.get('content-length')) || 0;
  const total = SIZE_HINT || headerTotal;
  const reader = res.body.getReader();
  const chunks = [];
  let loaded = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    loaded += value.byteLength;
    postProgress('download', total ? loaded / total : null, 'Reading file');
  }
  const out = new Uint8Array(loaded);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out.buffer;
}

async function fetchText(url, options) {
  const buffer = await fetchBuffer(url, options);
  return buffer == null ? null : decodeText(buffer);
}

function decodeText(buffer) {
  return new TextDecoder().decode(buffer);
}

// ---------------------------------------------------------------------------
// Materials helpers
// ---------------------------------------------------------------------------

function makeDefaultMaterial(geometry) {
  const hasColor = !!(geometry && geometry.attributes && geometry.attributes.color);
  return new THREE.MeshStandardMaterial({
    color: hasColor ? 0xffffff : 0xc4c8d0,
    roughness: 0.55,
    metalness: 0.05,
    side: THREE.DoubleSide,
    vertexColors: hasColor,
  });
}

function makePointsMaterial(geometry) {
  const hasColor = !!(geometry && geometry.attributes && geometry.attributes.color);
  return new THREE.PointsMaterial({
    size: 1,
    sizeAttenuation: true,
    vertexColors: hasColor,
    color: hasColor ? 0xffffff : 0x9fb6d6,
  });
}

function meshOrPoints(geometry) {
  const hasFaces = geometry.index ? geometry.index.count >= 3 : false;
  if (hasFaces) {
    if (!geometry.attributes.normal) geometry.computeVertexNormals();
    return new THREE.Mesh(geometry, makeDefaultMaterial(geometry));
  }
  return new THREE.Points(geometry, makePointsMaterial(geometry));
}

function materialsOf(material) {
  if (!material) return [];
  return Array.isArray(material) ? material : [material];
}

function mapMaterials(material, fn) {
  return Array.isArray(material) ? material.map(fn) : fn(material);
}

// ---------------------------------------------------------------------------
// Format loaders. Each returns { object, animations?, mixerRoot?, defaultZUp? }.
// ---------------------------------------------------------------------------

function gltfExtensionsUsed(buffer) {
  try {
    const u8 = new Uint8Array(buffer);
    let json;
    if (u8.length >= 20 && u8[0] === 0x67 && u8[1] === 0x6c && u8[2] === 0x54 && u8[3] === 0x46) {
      const dv = new DataView(buffer);
      const chunkLength = dv.getUint32(12, true);
      json = decodeText(u8.subarray(20, 20 + chunkLength));
    } else {
      json = decodeText(u8);
    }
    const parsed = JSON.parse(json);
    if (parsed.asset && parsed.asset.version && parseFloat(parsed.asset.version) < 2) {
      throw new ViewerError('unsupported_version',
        'This is a glTF 1.0 file. Only glTF 2.0 is supported — re-export or convert it to glTF 2.0.');
    }
    return new Set([...(parsed.extensionsUsed || []), ...(parsed.extensionsRequired || [])]);
  } catch (e) {
    if (e instanceof ViewerError) throw e;
    return null; // let GLTFLoader report the real problem
  }
}

const FORMAT_LOADERS = {
  async gltf(buffer) {
    const used = gltfExtensionsUsed(buffer);
    const needs = (name) => used == null || used.has(name);
    const { GLTFLoader } = await import('three/addons/loaders/GLTFLoader.js');
    const loader = new GLTFLoader(manager);
    let draco = null;
    let ktx2 = null;
    if (needs('KHR_draco_mesh_compression')) {
      const { DRACOLoader } = await import('three/addons/loaders/DRACOLoader.js');
      draco = new DRACOLoader().setDecoderPath(`${LIBS_BASE}draco/`).setDecoderConfig({ type: 'wasm' });
      loader.setDRACOLoader(draco);
    }
    if (needs('KHR_texture_basisu')) {
      const { KTX2Loader } = await import('three/addons/loaders/KTX2Loader.js');
      ktx2 = new KTX2Loader(manager).setTranscoderPath(`${LIBS_BASE}basis/`).detectSupport(renderer);
      loader.setKTX2Loader(ktx2);
    }
    if (needs('EXT_meshopt_compression') || needs('KHR_meshopt_compression')) {
      const { MeshoptDecoder } = await import('three/addons/libs/meshopt_decoder.module.js');
      loader.setMeshoptDecoder(MeshoptDecoder);
    }
    postProgress('parse', null, 'Processing model', true);
    try {
      const gltf = await new Promise((resolve, reject) => loader.parse(buffer, MODEL_BASE, resolve, reject));
      const object = gltf.scene || (gltf.scenes && gltf.scenes[0]);
      if (!object) throw new ViewerError('empty', 'This glTF file has no scene to display.');
      return { object, animations: gltf.animations || [] };
    } finally {
      if (draco) draco.dispose();
      // KTX2 textures are fully transcoded before GLTFLoader resolves.
      if (ktx2) ktx2.dispose();
    }
  },

  async obj(buffer) {
    const text = decodeText(buffer);
    const { OBJLoader } = await import('three/addons/loaders/OBJLoader.js');
    const loader = new OBJLoader(manager);

    // Material libraries referenced with `mtllib` (or a same-named sibling).
    const libLines = [];
    for (const m of text.matchAll(/^[ \t]*mtllib[ \t]+(.+?)[ \t]*$/gm)) libLines.push(m[1].trim());
    let implicit = false;
    if (!libLines.length) {
      const sibling = fileIndex.get(`${NAME.replace(/\.[^.]+$/, '')}.mtl`.toLowerCase());
      if (sibling) {
        libLines.push(sibling);
        implicit = true;
      }
    }

    const fetchMtl = (name) =>
      fetchText(resolveResourceUrl(MODEL_BASE + encodePath(name.replace(/\\/g, '/'))), { optional: true });

    let materialsLoaded = false;
    if (libLines.length) {
      postProgress('resources', null, 'Loading materials', true);
      const texts = [];
      for (const line of [...new Set(libLines)]) {
        // A line holds either one name containing spaces or several names.
        let mtl = await fetchMtl(line);
        if (mtl != null) {
          texts.push(mtl);
          continue;
        }
        let anyFound = false;
        for (const part of /\s/.test(line) ? line.split(/\s+/) : []) {
          mtl = await fetchMtl(part);
          if (mtl == null) continue;
          texts.push(mtl);
          anyFound = true;
        }
        if (!anyFound && !implicit) {
          warnings.push(`Material library "${line}" not found — showing the model without its materials.`);
        }
      }
      if (texts.length) {
        await registerTextureHandlers();
        const { MTLLoader } = await import('three/addons/loaders/MTLLoader.js');
        const mtlLoader = new MTLLoader(manager);
        mtlLoader.setMaterialOptions({ side: THREE.DoubleSide });
        const creator = mtlLoader.parse(texts.join('\n'), MODEL_BASE);
        creator.preload();
        loader.setMaterials(creator);
        materialsLoaded = true;
      }
    }

    postProgress('parse', null, 'Processing model', true);
    const object = loader.parse(text);
    if (!materialsLoaded) {
      object.traverse((o) => {
        if (o.isMesh) {
          if (!o.geometry.attributes.normal) o.geometry.computeVertexNormals();
          o.material = makeDefaultMaterial(o.geometry);
        }
      });
    }
    return { object };
  },

  async stl(buffer) {
    const { STLLoader } = await import('three/addons/loaders/STLLoader.js');
    postProgress('parse', null, 'Processing model', true);
    const geometry = new STLLoader(manager).parse(buffer);
    if (!geometry.attributes.normal) geometry.computeVertexNormals();
    const material = makeDefaultMaterial(geometry);
    if (geometry.hasColors) {
      material.vertexColors = true;
      material.color.set(0xffffff);
      if (geometry.alpha < 1) {
        material.transparent = true;
        material.opacity = geometry.alpha;
      }
    }
    return { object: new THREE.Mesh(geometry, material) };
  },

  async ply(buffer) {
    const { PLYLoader } = await import('three/addons/loaders/PLYLoader.js');
    postProgress('parse', null, 'Processing model', true);
    const geometry = new PLYLoader(manager).parse(buffer);
    return { object: meshOrPoints(geometry) };
  },

  async off(buffer) {
    postProgress('parse', null, 'Processing model', true);
    return { object: meshOrPoints(parseOFF(decodeText(buffer))) };
  },

  async xyz(buffer) {
    const { XYZLoader } = await import('three/addons/loaders/XYZLoader.js');
    postProgress('parse', null, 'Processing points', true);
    const geometry = new XYZLoader(manager).parse(decodeText(buffer));
    return { object: new THREE.Points(geometry, makePointsMaterial(geometry)) };
  },

  async pcd(buffer) {
    const { PCDLoader } = await import('three/addons/loaders/PCDLoader.js');
    postProgress('parse', null, 'Processing points', true);
    const points = new PCDLoader(manager).parse(buffer);
    points.material = makePointsMaterial(points.geometry);
    return { object: points };
  },

  async vtk(buffer) {
    const { VTKLoader } = await import('three/addons/loaders/VTKLoader.js');
    postProgress('parse', null, 'Processing model', true);
    if (buffer.byteLength < 250) {
      // VTKLoader sniffs the first 250 bytes; pad tiny files.
      const padded = new Uint8Array(256);
      padded.fill(0x20);
      padded.set(new Uint8Array(buffer));
      buffer = padded.buffer;
    }
    const geometry = new VTKLoader(manager).parse(buffer);
    return { object: meshOrPoints(geometry) };
  },

  async drc(buffer) {
    const { DRACOLoader } = await import('three/addons/loaders/DRACOLoader.js');
    const draco = new DRACOLoader().setDecoderPath(`${LIBS_BASE}draco/`).setDecoderConfig({ type: 'wasm' });
    postProgress('parse', null, 'Decoding Draco geometry', true);
    try {
      const geometry = await new Promise((resolve, reject) => draco.parse(buffer, resolve, reject));
      return { object: meshOrPoints(geometry) };
    } finally {
      draco.dispose();
    }
  },

  async fbx(buffer) {
    await registerTextureHandlers();
    const { FBXLoader } = await import('three/addons/loaders/FBXLoader.js');
    postProgress('parse', null, 'Processing model', true);
    const object = new FBXLoader(manager).parse(buffer, MODEL_BASE);
    return { object, animations: object.animations || [] };
  },

  async dae(buffer) {
    const { ColladaLoader } = await import('three/addons/loaders/ColladaLoader.js');
    postProgress('parse', null, 'Processing model', true);
    const collada = new ColladaLoader(manager).parse(decodeText(buffer), MODEL_BASE);
    if (!collada || !collada.scene) throw new ViewerError('parse_failed', 'This COLLADA file has no scene.');
    return { object: collada.scene, animations: collada.scene.animations || [] };
  },

  async kmz(buffer) {
    const { KMZLoader } = await import('three/addons/loaders/KMZLoader.js');
    postProgress('parse', null, 'Processing model', true);
    const kmz = new KMZLoader(manager).parse(buffer);
    return { object: kmz.scene, animations: (kmz.scene && kmz.scene.animations) || [] };
  },

  async '3ds'(buffer) {
    await registerTextureHandlers();
    const { TDSLoader } = await import('three/addons/loaders/TDSLoader.js');
    postProgress('parse', null, 'Processing model', true);
    return { object: new TDSLoader(manager).parse(buffer, MODEL_BASE) };
  },

  async '3mf'(buffer) {
    const { ThreeMFLoader } = await import('three/addons/loaders/3MFLoader.js');
    postProgress('parse', null, 'Processing model', true);
    return { object: new ThreeMFLoader(manager).parse(buffer) };
  },

  async amf(buffer) {
    const { AMFLoader } = await import('three/addons/loaders/AMFLoader.js');
    postProgress('parse', null, 'Processing model', true);
    return { object: new AMFLoader(manager).parse(buffer) };
  },

  async wrl(buffer) {
    await registerTextureHandlers();
    const { VRMLLoader } = await import('three/addons/loaders/VRMLLoader.js');
    postProgress('parse', null, 'Processing model', true);
    const text = decodeText(buffer);
    if (/^#VRML V1\.0/.test(text)) {
      throw new ViewerError('unsupported_version', 'VRML 1.0 files aren\'t supported. Only VRML 2.0 (VRML97) can be shown.');
    }
    const vrmlScene = new VRMLLoader(manager).parse(text, MODEL_BASE);
    // Drop the Background node's sky/ground spheres (renderOrder -Infinity):
    // the viewer controls the background and they'd break auto-framing.
    const group = new THREE.Group();
    const children = vrmlScene.children.filter((c) => c.renderOrder !== -Infinity);
    if (children.length) group.add(...children);
    return { object: group };
  },

  async usd(buffer) {
    const u8 = new Uint8Array(buffer);
    const crate = startsWithAscii(u8, 0, 'PXR-USDC');
    if (crate) throw unsupportedUsdc();
    const zip = inspectZip(u8);
    if (zip && (zip.name.toLowerCase().endsWith('.usdc') || zip.isCrate)) throw unsupportedUsdc();
    const { USDLoader } = await import('three/addons/loaders/USDLoader.js');
    postProgress('parse', null, 'Processing model', true);
    const loader = new USDLoader(manager);
    const object = zip ? loader.parse(buffer) : loader.parse(decodeText(buffer));
    return { object };
  },

  async lwo(buffer) {
    await registerTextureHandlers();
    const { LWOLoader } = await import('three/addons/loaders/LWOLoader.js');
    postProgress('parse', null, 'Processing model', true);
    const modelName = NAME.replace(/\.[^.]+$/, '');
    const result = new LWOLoader(manager).parse(buffer, MODEL_BASE, modelName);
    const group = new THREE.Group();
    for (const mesh of result.meshes || []) group.add(mesh);
    return { object: group };
  },

  async md2(buffer) {
    const { MD2Loader } = await import('three/addons/loaders/MD2Loader.js');
    postProgress('parse', null, 'Processing model', true);
    const geometry = new MD2Loader(manager).parse(buffer);
    const material = makeDefaultMaterial(geometry);
    // MD2 skins live next to the model; try common image types.
    const stem = NAME.replace(/\.[^.]+$/, '');
    for (const e of ['png', 'jpg', 'jpeg', 'tga']) {
      const skin = fileIndex.get(`${stem}.${e}`.toLowerCase());
      if (!skin) continue;
      if (e === 'tga') await registerTextureHandlers();
      const handler = manager.getHandler(skin);
      const texLoader = handler || new THREE.TextureLoader(manager);
      const texture = texLoader.load(MODEL_BASE + encodePath(skin), requestRender);
      texture.colorSpace = THREE.SRGBColorSpace;
      material.map = texture;
      material.color.set(0xffffff);
      break;
    }
    const mesh = new THREE.Mesh(geometry, material);
    return { object: mesh, animations: geometry.animations || [], mixerRoot: mesh };
  },

  async vox(buffer) {
    const { VOXLoader, VOXMesh } = await import('three/addons/loaders/VOXLoader.js');
    postProgress('parse', null, 'Processing voxels', true);
    const chunks = new VOXLoader(manager).parse(buffer);
    const group = new THREE.Group();
    for (const chunk of chunks) group.add(new VOXMesh(chunk));
    return { object: group };
  },

  async gcode(buffer) {
    const { GCodeLoader } = await import('three/addons/loaders/GCodeLoader.js');
    postProgress('parse', null, 'Processing tool paths', true);
    return { object: new GCodeLoader(manager).parse(decodeText(buffer)) };
  },

  async '3dm'() {
    throw new ViewerError('unsupported_format',
      'Rhino .3dm files aren\'t supported by the offline viewer. Export the model as OBJ, STL or glTF from Rhino.');
  },
};

const LOADER_ALIASES = {
  glb: 'gltf', vrml: 'wrl', usdz: 'usd', usda: 'usd', usdc: 'usd', vtp: 'vtk', gco: 'gcode',
};

function unsupportedUsdc() {
  return new ViewerError('unsupported_compression',
    'This USD file uses the binary "USDC" (crate) encoding, which the offline viewer can\'t read yet. ' +
    'USDA text files and USDZ packages with USDA content are supported.');
}

function startsWithAscii(u8, offset, text) {
  if (u8.length < offset + text.length) return false;
  for (let i = 0; i < text.length; i++) {
    if (u8[offset + i] !== text.charCodeAt(i)) return false;
  }
  return true;
}

// First entry of a ZIP (USDZ) archive: { name, isCrate } or null.
function inspectZip(u8) {
  if (!(u8.length > 30 && u8[0] === 0x50 && u8[1] === 0x4b && u8[2] === 0x03 && u8[3] === 0x04)) return null;
  const dv = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
  const nameLength = dv.getUint16(26, true);
  const extraLength = dv.getUint16(28, true);
  const name = decodeText(u8.subarray(30, 30 + nameLength));
  const dataStart = 30 + nameLength + extraLength;
  return { name, isCrate: startsWithAscii(u8, dataStart, 'PXR-USDC') };
}

// ---------------------------------------------------------------------------
// OFF (Object File Format) parser: OFF / COFF / NOFF / CNOFF / STOFF headers,
// polygon faces (fan-triangulated), optional per-vertex and per-face colours.
// ---------------------------------------------------------------------------

function parseOFF(text) {
  const lines = text.split(/\r?\n/);
  let li = 0;
  const nextLine = () => {
    while (li < lines.length) {
      let line = lines[li++];
      const hash = line.indexOf('#');
      if (hash >= 0) line = line.slice(0, hash);
      line = line.trim();
      if (line) return line;
    }
    return null;
  };

  let line = nextLine();
  if (line == null) throw new ViewerError('parse_failed', 'This OFF file is empty.');
  let prefix = '';
  let tokens = line.split(/\s+/);
  if (/OFF$/i.test(tokens[0])) {
    prefix = tokens[0].slice(0, -3);
    if (tokens[1] && /BINARY/i.test(tokens[1])) {
      throw new ViewerError('unsupported_format', 'Binary OFF files aren\'t supported.');
    }
    tokens = tokens.slice(1);
    if (!tokens.length) tokens = (nextLine() || '').split(/\s+/);
  }
  // "4OFF" (homogeneous) and "nOFF" (n-dimensional) aren't plain 3D meshes.
  if (prefix.includes('4') || prefix.endsWith('n')) {
    throw new ViewerError('unsupported_format', 'Higher-dimensional OFF files aren\'t supported.');
  }
  const flags = prefix.toUpperCase().replace('ST', '');
  const hasColors = flags.includes('C');
  const hasNormals = flags.includes('N');

  const nv = parseInt(tokens[0], 10);
  const nf = parseInt(tokens[1], 10) || 0;
  if (!(nv > 0)) throw new ViewerError('parse_failed', 'This OFF file has no vertices.');

  const positions = new Float32Array(nv * 3);
  const vColors = hasColors ? new Float32Array(nv * 3) : null;
  let colorScale = 1;
  for (let i = 0; i < nv; i++) {
    const l = nextLine();
    if (l == null) throw new ViewerError('parse_failed', 'This OFF file ends early (missing vertices).');
    const p = l.split(/\s+/);
    positions[i * 3] = +p[0];
    positions[i * 3 + 1] = +p[1];
    positions[i * 3 + 2] = +p[2];
    let k = 3;
    if (hasNormals) k += 3;
    if (vColors) {
      for (let c = 0; c < 3; c++) {
        const v = +p[k + c] || 0;
        if (v > 1) colorScale = 255;
        vColors[i * 3 + c] = v;
      }
    }
  }

  const tris = [];
  const faceColors = [];
  let anyFaceColor = false;
  let faceColorScale = 1;
  for (let f = 0; f < nf; f++) {
    const l = nextLine();
    if (l == null) break;
    const p = l.split(/\s+/).map(Number);
    const n = p[0];
    if (!(n >= 3)) continue;
    const verts = p.slice(1, 1 + n);
    const rest = p.slice(1 + n);
    let color = null;
    if (rest.length >= 3) {
      color = [rest[0], rest[1], rest[2]];
      if (color.some((v) => v > 1)) faceColorScale = 255;
      anyFaceColor = true;
    }
    for (let i = 1; i < n - 1; i++) {
      tris.push(verts[0], verts[i], verts[i + 1]);
      faceColors.push(color);
    }
  }

  const geometry = new THREE.BufferGeometry();
  const tmp = new THREE.Color();
  const toLinear = (r, g, b, scale) => tmp.setRGB(r / scale, g / scale, b / scale, THREE.SRGBColorSpace);

  if (anyFaceColor) {
    // Per-face colours need unshared vertices.
    const triCount = tris.length / 3;
    const pos = new Float32Array(tris.length * 3);
    const col = new Float32Array(tris.length * 3);
    for (let t = 0; t < triCount; t++) {
      const fc = faceColors[t];
      for (let c = 0; c < 3; c++) {
        const vi = tris[t * 3 + c];
        const o = (t * 3 + c) * 3;
        pos[o] = positions[vi * 3];
        pos[o + 1] = positions[vi * 3 + 1];
        pos[o + 2] = positions[vi * 3 + 2];
        if (fc) toLinear(fc[0], fc[1], fc[2], faceColorScale);
        else if (vColors) toLinear(vColors[vi * 3], vColors[vi * 3 + 1], vColors[vi * 3 + 2], colorScale);
        else tmp.setRGB(0.77, 0.78, 0.82, THREE.SRGBColorSpace);
        col[o] = tmp.r;
        col[o + 1] = tmp.g;
        col[o + 2] = tmp.b;
      }
    }
    geometry.setAttribute('position', new THREE.BufferAttribute(pos, 3));
    geometry.setAttribute('color', new THREE.BufferAttribute(col, 3));
    // Give the geometry a trivial index so it's treated as a mesh.
    const index = new Uint32Array(tris.length);
    for (let i = 0; i < index.length; i++) index[i] = i;
    geometry.setIndex(new THREE.BufferAttribute(index, 1));
  } else {
    geometry.setAttribute('position', new THREE.BufferAttribute(positions, 3));
    if (vColors) {
      for (let i = 0; i < nv; i++) {
        toLinear(vColors[i * 3], vColors[i * 3 + 1], vColors[i * 3 + 2], colorScale);
        vColors[i * 3] = tmp.r;
        vColors[i * 3 + 1] = tmp.g;
        vColors[i * 3 + 2] = tmp.b;
      }
      geometry.setAttribute('color', new THREE.BufferAttribute(vColors, 3));
    }
    if (tris.length) {
      const index = nv > 65535 ? new Uint32Array(tris) : new Uint16Array(tris);
      geometry.setIndex(new THREE.BufferAttribute(index, 1));
    }
  }
  return geometry;
}

// ---------------------------------------------------------------------------
// Scene setup after load
// ---------------------------------------------------------------------------

function prepareModel(object) {
  hasPoints = false;
  hasMeshes = false;
  object.traverse((o) => {
    if (o.isMesh) {
      hasMeshes = true;
      const g = o.geometry;
      if (g && g.attributes && g.attributes.position && !g.attributes.normal) {
        const needsNormals = materialsOf(o.material).some((m) => m && !m.isMeshBasicMaterial && !m.isShaderMaterial);
        if (needsNormals) g.computeVertexNormals();
      }
      originalMaterials.set(o, o.material);
    } else if (o.isPoints) {
      hasPoints = true;
    }
  });
}

function computeBox(object) {
  object.updateMatrixWorld(true);
  return new THREE.Box3().setFromObject(object);
}

function recenter() {
  modelRoot.position.set(0, 0, 0);
  orient.rotation.set(state.zUp ? -Math.PI / 2 : 0, 0, 0);
  modelRoot.updateMatrixWorld(true);
  const box = computeBox(orient);
  const finite = [box.min.x, box.min.y, box.min.z, box.max.x, box.max.y, box.max.z].every(Number.isFinite);
  if (box.isEmpty() || !finite) {
    throw new ViewerError('empty', 'This file doesn\'t contain any visible geometry.');
  }
  const center = box.getCenter(new THREE.Vector3());
  box.getSize(bounds.size);
  bounds.radius = Math.max(bounds.size.length() / 2, 1e-6);
  modelRoot.position.set(-center.x, -box.min.y, -center.z);
  modelRoot.updateMatrixWorld(true);
  updateHelpers();
  updatePointSizes();
}

function frameCamera(animate) {
  const r = bounds.radius;
  const vFov = THREE.MathUtils.degToRad(camera.fov);
  const hFov = 2 * Math.atan(Math.tan(vFov / 2) * camera.aspect);
  const distance = Math.max(r / Math.sin(vFov / 2), r / Math.sin(hFov / 2)) * 1.08;
  const target = new THREE.Vector3(0, bounds.size.y / 2, 0);
  const dir = new THREE.Vector3(0.6, 0.45, 1).normalize();
  const position = target.clone().addScaledVector(dir, distance);

  camera.near = Math.max(r / 1000, distance / 2000);
  camera.far = distance * 20 + r * 4;
  camera.updateProjectionMatrix();
  controls.minDistance = r * 0.02;
  controls.maxDistance = distance * 10;

  home.position.copy(position);
  home.target.copy(target);

  if (animate) {
    animateView(position, target);
  } else {
    tween = null;
    camera.position.copy(position);
    controls.target.copy(target);
    camera.lookAt(target);
    controls.update();
  }
  requestRender();
}

function animateView(position, target) {
  tween = {
    p0: camera.position.clone(),
    p1: position.clone(),
    t0: controls.target.clone(),
    t1: target.clone(),
    start: performance.now(),
    duration: 450,
  };
  requestRender();
}

function resetView() {
  if (!modelReady) return;
  animateView(home.position, home.target);
}

function niceGrid(maxDim) {
  const unit = Math.pow(10, Math.floor(Math.log10(Math.max(maxDim, 1e-9))));
  let size = Math.ceil((maxDim * 2.5) / unit) * unit;
  let divisions = Math.round((size / unit) * 2);
  while (divisions > 60) divisions = Math.round(divisions / 2);
  if (divisions < 4) divisions = 4;
  if (!(size > 0)) size = 1;
  return { size, divisions };
}

function gridColors() {
  const light = state.background === 'light';
  return light ? [0x8a9099, 0xc3c8d0] : [0x9aa0aa, 0x4a4f58];
}

function updateHelpers() {
  if (gridHelper) {
    scene.remove(gridHelper);
    gridHelper.geometry.dispose();
    gridHelper.material.dispose();
    gridHelper = null;
  }
  if (axesHelper) {
    scene.remove(axesHelper);
    axesHelper.geometry.dispose();
    axesHelper.material.dispose();
    axesHelper = null;
  }
  const maxDim = Math.max(bounds.size.x, bounds.size.y, bounds.size.z, 1e-6);
  const { size, divisions } = niceGrid(Math.max(bounds.size.x, bounds.size.z, maxDim * 0.5));
  const [c1, c2] = gridColors();
  gridHelper = new THREE.GridHelper(size, divisions, c1, c2);
  gridHelper.material.transparent = true;
  gridHelper.material.opacity = 0.55;
  gridHelper.material.depthWrite = false;
  gridHelper.renderOrder = -1;
  gridHelper.visible = state.grid;
  scene.add(gridHelper);

  axesHelper = new THREE.AxesHelper(maxDim * 0.75);
  axesHelper.material.depthTest = false;
  axesHelper.renderOrder = 10;
  axesHelper.visible = state.axes;
  scene.add(axesHelper);
}

function updatePointSizes() {
  if (!model || !hasPoints) return;
  let total = 0;
  model.traverse((o) => {
    if (o.isPoints && o.geometry.attributes.position) total += o.geometry.attributes.position.count;
  });
  const r = bounds.radius;
  const spacing = r * Math.sqrt((4 * Math.PI) / Math.max(total, 1));
  const base = THREE.MathUtils.clamp(spacing * 1.2, r / 4000, r / 40);
  model.traverse((o) => {
    if (!o.isPoints) return;
    for (const m of materialsOf(o.material)) {
      if (m.isPointsMaterial) {
        m.sizeAttenuation = true;
        m.size = base * state.pointScale;
      }
    }
  });
  requestRender();
}

function flatVariant(material) {
  if (!material) return material;
  let cached = flatMaterialCache.get(material);
  if (cached) return cached;
  if ('flatShading' in material && !material.isMeshBasicMaterial) {
    cached = material.clone();
    cached.flatShading = true;
  } else {
    cached = new THREE.MeshStandardMaterial({
      color: material.color ? material.color.clone() : 0xc4c8d0,
      map: material.map || null,
      vertexColors: !!material.vertexColors,
      side: material.side,
      transparent: material.transparent,
      opacity: material.opacity,
      flatShading: true,
      roughness: 0.6,
    });
  }
  cached.needsUpdate = true;
  flatMaterialCache.set(material, cached);
  return cached;
}

function applyShading() {
  for (const [mesh, original] of originalMaterials) {
    if (state.shading === 'normals') {
      mesh.material = mapMaterials(original, () => normalMaterial);
    } else if (state.shading === 'flat') {
      mesh.material = mapMaterials(original, flatVariant);
    } else {
      mesh.material = original;
    }
  }
  applyWireframe();
}

const wireframeOriginal = new WeakMap();
function applyWireframe() {
  for (const mesh of originalMaterials.keys()) {
    for (const m of materialsOf(mesh.material)) {
      if (!m || !('wireframe' in m)) continue;
      if (!wireframeOriginal.has(m)) wireframeOriginal.set(m, m.wireframe);
      m.wireframe = state.wireframe ? true : wireframeOriginal.get(m);
    }
  }
  requestRender();
}

function applyBackground() {
  document.body.classList.remove('bg-dark', 'bg-light', 'bg-gradient', 'bg-transparent');
  document.body.classList.add(`bg-${state.background}`);
  if (gridHelper) updateHelpers();
  requestRender();
}

function normalizeBackground(value) {
  return ['dark', 'light', 'gradient', 'transparent'].includes(value) ? value : 'dark';
}

// ---------------------------------------------------------------------------
// Animations
// ---------------------------------------------------------------------------

const animation = {
  mixer: null,
  clips: [],
  index: -2, // -2 none selected, -1 all clips, >= 0 single clip
  playing: false,
};

function setupAnimations(root, clips) {
  animation.clips = (clips || []).filter((c) => c && c.tracks && c.tracks.length && c.duration > 0);
  if (!animation.clips.length) return;
  animation.mixer = new THREE.AnimationMixer(root);
  playAnimation(0);
}

function activeActions() {
  if (!animation.mixer) return [];
  const list = animation.index === -1 ? animation.clips : [animation.clips[animation.index]];
  return list.filter(Boolean).map((clip) => animation.mixer.clipAction(clip));
}

function playAnimation(index) {
  if (!animation.mixer) return;
  const i = Number(index);
  if (!(i === -1 || (i >= 0 && i < animation.clips.length))) return;
  animation.mixer.stopAllAction();
  animation.index = i;
  for (const action of activeActions()) {
    action.reset();
    action.paused = false;
    action.play();
  }
  animation.playing = true;
  clock.getDelta();
  postAnimationState();
}

function setAnimationPaused(paused) {
  if (!animation.mixer || animation.index === -2) return;
  for (const action of activeActions()) action.paused = paused;
  animation.playing = !paused;
  clock.getDelta();
  requestRender();
  postAnimationState();
}

function stopAnimation() {
  if (!animation.mixer) return;
  animation.mixer.stopAllAction();
  animation.playing = false;
  animation.index = -2;
  requestRender();
  postAnimationState();
}

function postAnimationState() {
  post('animation', { index: animation.index, playing: animation.playing });
}

// ---------------------------------------------------------------------------
// Stats
// ---------------------------------------------------------------------------

function computeStats() {
  let meshes = 0;
  let vertices = 0;
  let triangles = 0;
  let points = 0;
  let lines = 0;
  let skinned = 0;
  const materials = new Set();
  const textures = new Set();
  model.traverse((o) => {
    const g = o.geometry;
    if (!g || !g.attributes || !g.attributes.position) return;
    const count = g.attributes.position.count;
    const instances = o.isInstancedMesh ? o.count : 1;
    if (o.isMesh) {
      meshes++;
      vertices += count * instances;
      const indexCount = g.index ? g.index.count : count;
      triangles += Math.floor(indexCount / 3) * instances;
      if (o.isSkinnedMesh) skinned++;
    } else if (o.isPoints) {
      points += count;
      vertices += count;
    } else if (o.isLine) {
      vertices += count;
      lines += o.isLineSegments ? Math.floor(count / 2) : Math.max(count - 1, 0);
    } else {
      return;
    }
    const mats = originalMaterials.get(o) || o.material;
    for (const m of materialsOf(mats)) {
      if (!m) continue;
      materials.add(m);
      for (const key of Object.keys(m)) {
        const value = m[key];
        if (value && value.isTexture) textures.add(value.source ? value.source.uuid : value.uuid);
      }
    }
  });
  return {
    format: FORMAT,
    meshes,
    vertices,
    triangles,
    points,
    lines,
    skinnedMeshes: skinned,
    materials: materials.size,
    textures: textures.size,
    animations: animation.clips.length,
    size: { x: bounds.size.x, y: bounds.size.y, z: bounds.size.z },
  };
}

function allWarnings() {
  const list = [...warnings];
  if (missingFiles.size) {
    const names = [...missingFiles];
    const shown = names.slice(0, 8).map((n) => `"${n}"`).join(', ');
    const more = names.length > 8 ? ` and ${names.length - 8} more` : '';
    list.push(`Missing or unreadable file${names.length > 1 ? 's' : ''}: ${shown}${more}.`);
  }
  return list;
}

let statsTimer = 0;
function scheduleStats() {
  if (!modelReady) return;
  clearTimeout(statsTimer);
  statsTimer = setTimeout(() => {
    post('stats', { stats: computeStats(), warnings: allWarnings() });
  }, 150);
}

function snapshotState() {
  return { ...state, hasPoints, hasMeshes };
}

// ---------------------------------------------------------------------------
// Screenshot
// ---------------------------------------------------------------------------

function paintBackground(ctx, w, h) {
  const bg = state.background;
  if (bg === 'transparent') return;
  let gradient;
  if (bg === 'gradient') {
    gradient = ctx.createLinearGradient(w * 0.45, 0, w * 0.55, h);
    gradient.addColorStop(0, '#3a4a6b');
    gradient.addColorStop(0.45, '#2a2f45');
    gradient.addColorStop(1, '#15161d');
  } else {
    const r = Math.hypot(w, h) * 0.6;
    gradient = ctx.createRadialGradient(w / 2, h * 0.4, 0, w / 2, h * 0.4, r);
    const stops = bg === 'light'
      ? ['#ffffff', '#eceff4', '#d6dbe3']
      : ['#33363f', '#1c1e24', '#111216'];
    gradient.addColorStop(0, stops[0]);
    gradient.addColorStop(0.55, stops[1]);
    gradient.addColorStop(1, stops[2]);
  }
  ctx.fillStyle = gradient;
  ctx.fillRect(0, 0, w, h);
}

function screenshot() {
  try {
    renderer.render(scene, camera);
    const src = renderer.domElement;
    const out = document.createElement('canvas');
    out.width = src.width;
    out.height = src.height;
    const ctx = out.getContext('2d');
    paintBackground(ctx, out.width, out.height);
    ctx.drawImage(src, 0, 0);
    post('screenshot', { dataUrl: out.toDataURL('image/png'), width: out.width, height: out.height });
  } catch (e) {
    post('screenshot', { error: String(e && e.message || e) });
  }
}

// ---------------------------------------------------------------------------
// Commands from Flutter
// ---------------------------------------------------------------------------

const COMMANDS = {
  resetView,
  setAutoRotate(on) {
    state.autoRotate = !!on;
    controls.autoRotate = state.autoRotate;
    clock.getDelta();
    requestRender();
  },
  setWireframe(on) {
    state.wireframe = !!on;
    applyWireframe();
  },
  setGrid(on) {
    state.grid = !!on;
    if (gridHelper) gridHelper.visible = state.grid;
    requestRender();
  },
  setAxes(on) {
    state.axes = !!on;
    if (axesHelper) axesHelper.visible = state.axes;
    requestRender();
  },
  setBackground(value) {
    state.background = normalizeBackground(value);
    applyBackground();
  },
  setShading(mode) {
    state.shading = ['original', 'flat', 'normals'].includes(mode) ? mode : 'original';
    applyShading();
  },
  setZUp(on) {
    state.zUp = !!on;
    if (!model) return;
    recenter();
    frameCamera(true);
    scheduleStats();
  },
  setPointSize(scale) {
    const s = Number(scale);
    state.pointScale = Number.isFinite(s) ? THREE.MathUtils.clamp(s, 0.1, 10) : 1;
    updatePointSizes();
  },
  playAnimation,
  pauseAnimation: () => setAnimationPaused(true),
  resumeAnimation: () => setAnimationPaused(false),
  toggleAnimation: () => {
    if (animation.index === -2) playAnimation(0);
    else setAnimationPaused(animation.playing);
  },
  stopAnimation,
  screenshot,
};

window.viewer = {
  command(name, arg) {
    const fn = COMMANDS[name];
    if (!fn) return false;
    try {
      fn(arg);
    } catch (e) {
      post('log', { level: 'error', message: `${name} failed: ${e && e.message || e}` });
      return false;
    }
    if (name !== 'screenshot' && name !== 'resetView') post('state', { state: snapshotState() });
    return true;
  },
};

// ---------------------------------------------------------------------------
// Error descriptions
// ---------------------------------------------------------------------------

function describeError(error) {
  if (error instanceof ViewerError) {
    return { code: error.code, message: error.message, detail: error.detail || null };
  }
  const raw = String((error && error.message) || error || 'Unknown error');
  const fetchFail = /fetch for "([^"]+)" responded with (\d+)/.exec(raw);
  if (fetchFail) {
    return { code: 'missing_file', message: `Missing file "${displayNameOf(fetchFail[1])}" referenced by the model.`, detail: raw };
  }
  let m = /Unknown extension "([^"]+)"/.exec(raw);
  if (m) {
    return { code: 'unsupported_extension', message: `This glTF needs the unsupported extension ${m[1]}.`, detail: raw };
  }
  if (/glTF versions >=\s*2\.0/i.test(raw)) {
    return { code: 'unsupported_version', message: 'This is a glTF 1.0 file. Only glTF 2.0 is supported.', detail: raw };
  }
  if (/draco/i.test(raw)) {
    return { code: 'unsupported_compression', message: 'Couldn\'t decode the Draco-compressed geometry in this file.', detail: raw };
  }
  if (/ktx2|basis|transcoder/i.test(raw)) {
    return { code: 'unsupported_compression', message: 'Couldn\'t decode the KTX2/Basis compressed textures in this file.', detail: raw };
  }
  if (/meshopt/i.test(raw)) {
    return { code: 'unsupported_compression', message: 'Couldn\'t decode the meshopt-compressed data in this file.', detail: raw };
  }
  m = /FBX version not supported, FileVersion: (\d+)/.exec(raw);
  if (m) {
    return {
      code: 'unsupported_version',
      message: `This FBX file is version ${m[1]}. Only FBX 7.0 (2011) and newer can be shown — re-export it with a newer FBX version.`,
      detail: raw,
    };
  }
  if (/Unknown format|Cannot find|not a valid|Invalid|Unexpected token|JSON/i.test(raw)) {
    return { code: 'parse_failed', message: `This doesn't look like a valid ${FORMAT} file, or it's damaged.`, detail: raw };
  }
  if (error instanceof RangeError || /allocation failed|out of memory|Array buffer/i.test(raw)) {
    return { code: 'out_of_memory', message: 'The model is too large to open on this device.', detail: raw };
  }
  return { code: 'parse_failed', message: `Couldn't open this ${FORMAT} file.`, detail: raw };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  if (!SRC) throw new ViewerError('bad_request', 'No model file was given to the viewer.');
  const key = LOADER_ALIASES[EXT] || EXT;
  const load = FORMAT_LOADERS[key];
  if (!load) {
    throw new ViewerError('unsupported_format', `".${EXT}" files aren't supported by the 3D viewer.`);
  }

  postProgress('download', 0, 'Reading file', true);
  const buffer = await fetchBuffer(SRC, { progress: true });
  if (!buffer.byteLength) throw new ViewerError('empty', 'This file is empty.');

  const result = await load(buffer);
  if (!result || !result.object) throw new ViewerError('empty', 'Nothing could be read from this file.');

  model = result.object;
  orient.add(model);
  prepareModel(model);
  recenter();
  frameCamera(false);
  setupAnimations(result.mixerRoot || model, result.animations);
  applyShading();

  modelReady = true;
  requestRender();
  post('loaded', {
    stats: computeStats(),
    warnings: allWarnings(),
    animations: animation.clips.map((c, i) => ({ index: i, name: c.name || `Animation ${i + 1}`, duration: c.duration })),
    animationIndex: animation.index,
    animationPlaying: animation.playing,
    state: snapshotState(),
  });
}

main().catch((error) => {
  console.error(error);
  const described = describeError(error);
  post('error', described);
});

// ---------------------------------------------------------------------------
// Utils
// ---------------------------------------------------------------------------

function extensionOf(url) {
  const name = (url || '').split(/[?#]/)[0].split('/').pop() || '';
  const dot = name.lastIndexOf('.');
  return dot >= 0 ? name.slice(dot + 1) : '';
}

function safeDecode(s) {
  try {
    return decodeURIComponent(s);
  } catch (_) {
    return s;
  }
}
