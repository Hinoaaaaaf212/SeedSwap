'use strict';
// Static in-place RomFS views for lazy mode.
//
// The lazy loader builds a view when a game mounts its RomFS. A process that
// mounted before activation never does that again: HOME (qlaunch) mounts its
// RomFS once at boot and keeps that storage until it exits, but it still
// reads files through it later (its palette after a theme change in System
// Settings). The native reader identifies such a storage on first use by
// size, 80-byte header, one file entry and a 128-byte data prefix, and serves
// the listed files from an inline payload at their original offsets.
//
// Files must keep their size: the reading process may have cached the RomFS
// tables at boot, so no record, table or offset may change.
//
// A spec is JSON:
//   {"titleId":"0400000000001000","files":[
//     {"path":"/Layout2/Palettes/White.buip","source":"relative/or/absolute/file",
//      "originalSha256":"<SHA-256 of the console's original file>"}]}
// The original hash pins the content the replacement was made from: a console
// with different original bytes stops the installation before any hook.
const fs=require('node:fs'),path=require('node:path');
const {check,sha,titleId}=require('./common.cjs');
const {isUncertain}=require('./game-files/uncertain.cjs');
const EDGE=32,SAMPLE=768,MAX_FILES=64,MAX_PAYLOAD=1024*1024;

function readSpec(file){
 const where=path.resolve(file),spec=JSON.parse(fs.readFileSync(where,'utf8')),base=path.dirname(where);
 check(spec&&Array.isArray(spec.files)&&spec.files.length>0&&spec.files.length<=MAX_FILES,'A static view needs 1 to '+MAX_FILES+' files: '+where);
 const files=spec.files.map(f=>{
  check(typeof f.path==='string'&&f.path.startsWith('/')&&Buffer.byteLength(f.path)<=0x300&&!/[\\\0]/.test(f.path)&&!f.path.slice(1).split('/').some(p=>!p||p==='.'||p==='..'),'Invalid static RomFS path: '+f.path);
  check(typeof f.originalSha256==='string'&&/^[0-9a-f]{64}$/.test(f.originalSha256),'Static view needs the original SHA-256 of '+f.path);
  const source=path.resolve(base,f.source),bytes=fs.readFileSync(source);check(bytes.length>0,'Empty static replacement: '+f.path);
  check(sha(bytes)!==f.originalSha256,'Static replacement equals the original: '+f.path);
  return{path:f.path,source,bytes,originalSha256:f.originalSha256,replacementSha256:sha(bytes)};
 });
 check(new Set(files.map(f=>f.path)).size===files.length,'Duplicate static RomFS path in '+where);
 check(files.reduce((n,f)=>n+f.bytes.length,0)<=MAX_PAYLOAD,'Static replacements exceed '+MAX_PAYLOAD+' bytes');
 return{file:where,titleId:titleId(spec.titleId),files};
}

// Read-only: capture the title's RomFS identity and file table, then read each
// original file with EDGE bytes on both sides through a second mount.
async function prepareStaticViews(run,specs,directory){
 const {captureGame,openSelected}=require('./content.cjs'),{attachGame,createGameFiles}=require('./game-files/mount-api.cjs'),{captured,viewIdentity}=require('./romfs.cjs');
 const views=[],parts=[];let size=0;
 for(const spec of specs){
  check(!views.some(v=>v.titleId===spec.titleId),'One static view per title: '+spec.titleId);
  const capture=path.join(directory,'static-views',spec.titleId);
  const inventory=await captureGame(run,{titleId:spec.titleId,romfs:spec.files.map(f=>({type:'file',path:f.path})),exefs:[],patches:[],stubs:[]},capture);
  const mount=inventory.romfs;check(mount?.identity&&Number.isSafeInteger(mount.size),'No RomFS identity for '+spec.titleId);
  const header=captured(capture,mount,0,80),entries=new Map(mount.entries.filter(e=>e.type==='file').map(e=>[e.path,e]));
  const a=await attachGame(run),files=createGameFiles(a),segments=[],staticFiles=[];let live,uncertain=false;
  try{
   live=await openSelected(a,files,{...mount.selection,resolvedSource:mount.source});
   check(live.size===mount.size&&live.source.contentId===mount.source.contentId&&live.source.version===mount.source.version,'RomFS changed between reads: '+spec.titleId);
   for(const f of spec.files){
    const e=entries.get(f.path);check(e,'Not in the original RomFS of '+spec.titleId+': '+f.path);
    check(e.size===f.bytes.length,f.path+' must keep its size: original '+e.size+' bytes, replacement '+f.bytes.length);
    check(Number.isSafeInteger(e.offset)&&e.offset>=80+EDGE&&e.offset+e.size+EDGE<=mount.size,'File too close to the storage edge: '+f.path);
    const around=await files.read(live,e.offset-EDGE,e.size+2*EDGE);check(around.length===e.size+2*EDGE,'Short original read: '+f.path);
    check(sha(around.subarray(EDGE,EDGE+e.size))===f.originalSha256,f.path+' on the console differs from the original this replacement was made from');
    segments.push({offset:e.offset,length:e.size,sourceOffset:size});
    staticFiles.push({path:f.path,offset:e.offset,size:e.size,payloadOffset:size,originalSha256:f.originalSha256,replacementSha256:f.replacementSha256,source:f.source,beforeHex:around.subarray(0,EDGE).toString('hex'),afterHex:around.subarray(EDGE+e.size).toString('hex')});
    parts.push(f.bytes);size+=e.size;
   }
  }catch(error){uncertain=isUncertain(error);throw error;}
  finally{if(!uncertain){if(live)await files.close(live);await a.close();}}
  segments.sort((x,y)=>x.offset-y.offset);
  for(let i=1;i<segments.length;i++)check(segments[i-1].offset+segments[i-1].length<=segments[i].offset,'Overlapping static files in '+spec.titleId);
  views.push({...viewIdentity(mount,{titleId:spec.titleId},header),virtualSize:mount.size,segments,resources:[],staticFiles,spec:spec.file});
 }
 return{views,payload:Buffer.concat(parts,size)};
}

// After activation: read every replaced byte, the header, and the EDGE bytes on
// both sides of each file through a fresh mount and the installed FS reader.
async function verifyStaticViews(run,plan,payload,controller,source){
 const {openSelected}=require('./content.cjs'),{attachGame,createGameFiles}=require('./game-files/mount-api.cjs'),{verifySamples}=require('./native/verify.cjs');
 const a=await attachGame(run),files=createGameFiles(a),report=[];let mount;
 try{
  for(const v of plan.views){
   mount=await openSelected(a,files,{...v.selection,resolvedSource:v.source});
   check(mount.source.contentId===v.source.contentId&&mount.source.version===v.source.version&&mount.size===v.virtualSize,'Static view storage identity/size differs: '+v.titleId);
   const samples=[{offset:0,length:80,expected:Buffer.from(v.headerHex,'hex')}];
   for(const f of v.staticFiles){
    const replacement=payload.subarray(f.payloadOffset,f.payloadOffset+f.size),before=Buffer.from(f.beforeHex,'hex'),after=Buffer.from(f.afterHex,'hex'),edge=Math.min(64,f.size);
    check(replacement.length===f.size&&sha(replacement)===f.replacementSha256,'Static payload differs: '+f.path);
    for(let at=0;at<f.size;at+=SAMPLE){const n=Math.min(SAMPLE,f.size-at);samples.push({offset:f.offset+at,length:n,expected:replacement.subarray(at,at+n)});}
    samples.push({offset:f.offset-before.length,length:before.length+edge,expected:Buffer.concat([before,replacement.subarray(0,edge)])});
    samples.push({offset:f.offset+f.size-edge,length:edge+after.length,expected:Buffer.concat([replacement.subarray(f.size-edge),after])});
    report.push({titleId:v.titleId,path:f.path,offset:f.offset,verifiedBytes:f.size,edgesVerified:true});
   }
   await verifySamples(a,controller,mount,samples,source.filesystem.object);
   await files.close(mount);mount=null;
  }
  return report;
 }catch(error){if(isUncertain(error))controller.c.pending=true;throw error;}
 finally{if(!controller.c.pending){if(mount)await files.close(mount);await a.close();}}
}
module.exports={readSpec,prepareStaticViews,verifyStaticViews,EDGE};
