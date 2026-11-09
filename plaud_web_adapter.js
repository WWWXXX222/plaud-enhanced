// Executed inside this app's own Plaud Web session. No credentials cross the bridge.
// Public upload contract rechecked on 2026-10-27; compatible releases are discovered automatically.
// The website's own client handles login, workspace authorization and token refresh.
// Resolve the current release's own exports and require its workspace authorization client.
// Resolve the contract from the modules loaded by the official page. Hashed
// filenames/export aliases are packaging details, not protocol versions.
const entryPattern = /^https:\/\/web-static\.plaud\.ai\/plaud-web3\/prod-[A-Za-z0-9_-]+\/js\/index\.[A-Za-z0-9_-]+\.js$/;
const incompatible = () => { throw new Error('OWNPLAUD_CONTRACT'); };
const only = values => { const unique = [...new Set(values)]; if (unique.length !== 1) incompatible(); return unique[0]; };
const functionSource = value => typeof value === 'function' ? Function.prototype.toString.call(value) : '';
const publicSource = async url => {
  const response = await fetch(url, {credentials:'omit', redirect:'error'});
  if (!response.ok) throw new Error('OWNPLAUD_CONNECTION');
  if (response.url !== url) incompatible();
  const text = await response.text();
  if (!text || text.length > 5*1024*1024) incompatible();
  return text;
};
async function discover(entryURL) {
  const entryText = await publicSource(entryURL);
  const chunks = [...entryText.matchAll(/(?:from\s*|import\s*)["'](\.\/app-initial-common\.[A-Za-z0-9_-]+\.chunk\.js)["']/g)].map(match => match[1]);
  const moduleURL = new URL(only(chunks), entryURL).href;
  const source = await publicSource(moduleURL);
  // All three upload operations must belong to the same exported client. Do
  // not guess among the generic, account and workspace HTTP clients.
  const owners = ['get_upload_presigned_url','merge_multipart','confirm_upload'].map(endpoint =>
    only([...source.matchAll(new RegExp('([A-Za-z_$][\\w$]*)\\.post\\(\\s*["\']/file/' + endpoint + '["\']', 'g'))].map(match => match[1])));
  const owner = only(owners);
  const exportGroups = [...source.matchAll(/export\s*\{([^{}]+)\}/g)];
  const aliases = exportGroups.flatMap(group => [...group[1].matchAll(/([A-Za-z_$][\w$]*)\s+as\s+([A-Za-z_$][\w$]*)/g)])
    .filter(match => match[1] === owner).map(match => match[2]);
  if (!aliases.length) incompatible();
  const client = await import(moduleURL);
  const http = only(aliases.map(name => client[name]));
  const storeFactory = only(Object.values(client).filter(value => typeof value === 'function' && value.$id === 'workspace'));
  if (!http || typeof http.post !== 'function' || typeof http.get !== 'function' || typeof http.resolveUrl !== 'function' ||
      http.resolveUrl('/file/confirm_upload') !== '/file/confirm_upload' || !functionSource(http.doFetch).includes('metaback')) incompatible();
  const requestHandlers = http.axiosInst?.interceptors?.request?.handlers;
  const responseHandlers = http.axiosInst?.interceptors?.response?.handlers;
  if (!Array.isArray(requestHandlers) || !requestHandlers.some(handler => {
    const text = functionSource(handler?.fulfilled);
    return ['currentWorkspace','baseURL','workspaceToken','Authorization'].every(key => text.includes(key));
  }) || !Array.isArray(responseHandlers) || !responseHandlers.some(Boolean)) incompatible();
  return {http,storeFactory};
}
async function currentClient(entryURL) {
  // Share discovery only, never upload results or a snapshot of account state.
  // This cache lives in the site's page and disappears on navigation/logout.
  const key = '__ownPlaudWorkspaceContractV1';
  let cache = globalThis[key];
  if (!cache || cache.entry !== entryURL) {
    cache = {entry:entryURL,promise:discover(entryURL)};
    globalThis[key] = cache;
  }
  try { return await cache.promise; }
  catch (error) { if (globalThis[key] === cache) delete globalThis[key]; throw error; }
}
let expired = false;
const work = async () => {
try {
  if (location.origin !== 'https://web.plaud.ai') return {ok:false, code:'LOGIN'};
  // An unfinished/failed document is not evidence of a new Plaud release.
  // Keep it retryable; an actual unrecognized entry still fails closed below.
  if (document.readyState === 'loading' || document.scripts.length === 0) return {ok:false, code:'CONNECTION'};
  const entryURL = only([...document.scripts].map(script => script.src).filter(src => entryPattern.test(src)));
  const {http,storeFactory} = await currentClient(entryURL);
  if (expired) return {ok:false,code:'CONNECTION'};
  const workspace = storeFactory();
  if (!workspace.sessionReady) return {ok:false, code:'CONNECTION'};
  if (!workspace.currentWorkspaceId) return {ok:false, code:'LOGIN'};
  const ws = workspace.currentWorkspaceId;
  if (action === 'identity') return {ok:true, workspace_id:ws};
  if (payload.workspace_id !== ws) return {ok:false, code:'ACCOUNT'};
  let response;
  if (action === 'presign') {
    response = await http.post('/file/get_upload_presigned_url', {filesize:payload.size, file_type:'MP3'}, {metaback:true});
    if (response.status !== 0) return {ok:false, code:'SERVICE', status:response.status};
    return {ok:true, ...response.data};
  }
  if (action === 'merge') {
    response = await http.post('/file/merge_multipart', {upload_id:payload.upload_id,object_name:payload.object_name,parts:payload.parts}, {metaback:true});
  } else if (action === 'confirm') {
    response = await http.post('/file/confirm_upload', {
      upload_id:payload.upload_id,object_name:payload.object_name,scene:102,is_tmp:0,
      support_mul_summ:true,file_type:'MP3',filename:payload.title,start_time:payload.recording_id,
      session_id:Math.floor(payload.recording_id/1000),serial_number:payload.serial_number,
      timezone:-new Date().getTimezoneOffset()/60
    }, {metaback:true});
    if (response.status !== 0) return {ok:false, code:'SERVICE', status:response.status};
    const file = response.data_file || response.data;
    return {ok:true, file_id:file?.id || file?.file_id};
  } else if (action === 'generate') {
    if (!/^[a-f0-9]{32}$/.test(payload.file_id)) return {ok:false, code:'FILE'};
    const language = payload.language ?? 'auto';
    if (!['auto','zh','en'].includes(language)) return {ok:false,code:'LANGUAGE'};
    response = await http.post(`/ai/transsumm/${payload.file_id}`, {
      is_reload:0,summ_type:'AUTO-SELECT',summ_type_type:'system',
      info:JSON.stringify({language,diarization:1,llm:'auto'}),support_mul_summ:true,
      timezone:-new Date().getTimezoneOffset()/60
    }, {metaback:true});
    return [0,1].includes(response.status)
      ? {ok:true,complete:response.status===1}
      : {ok:false,code:'SERVICE',status:response.status};
  } else return {ok:false,code:'ACTION'};
  return response.status === 0 ? {ok:true} : {ok:false,code:'SERVICE',status:response.status};
} catch (error) {
  // Raw exceptions can contain request headers or signed URLs. Never return them.
  return {ok:false,code:error?.message === 'OWNPLAUD_CONTRACT' ? 'VERSION' : 'CONNECTION'};
}
};
// Bound a stalled website client/import promise too, not just audio PUTs.
// Confirmation retries retain the stable recording ID/serial in the native
// checkpoint because the outcome of a timed-out request may be ambiguous.
let timer;
try {
  return await Promise.race([
    work(),
    new Promise(resolve => { timer = setTimeout(() => { expired = true; resolve({ok:false,code:'CONNECTION'}); }, 120000); })
  ]);
} finally {
  if (timer !== undefined) clearTimeout(timer);
}
