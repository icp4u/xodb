"""Saved-profile acceptance helper for the periodic pe-wine --profile lane."""
import hashlib, json, shutil, struct, time
from client import Client

def ready(c,opened=False):
 deadline=time.monotonic()+30
 while True:
  s=c.inspect('get_archive_status')
  if s['job']['done']:
   assert s['job']['error_name'] is None,s
   if not opened or s['recorded_origin'] is not None:return s
  assert time.monotonic()<deadline,s
  time.sleep(.002)

def reconstructed(c,ordinal):
 cap=c.inspect('get_profile')['capture'];deadline=time.monotonic()+30
 while True:
  value=c.inspect('get_profile_stack',capture_id=cap['id'],revision=cap['revision'],sample=ordinal,stack_limit=0)
  if not value['pending']:
   assert value['derived'] is not None,value
   return value['derived']
  assert time.monotonic()<deadline,value
  time.sleep(.002)

def graph(c,basis='recorded'):
 cap=c.inspect('get_profile')['capture'];deadline=time.monotonic()+30;rows=[]
 args=dict(capture_id=cap['id'],revision=cap['revision'],basis=basis,limit=64)
 while True:
  response=c.tool('get_flamegraph',**args)['result']
  if response.get('isError'):
   assert response['content']==[dict(type='text',text='ArchiveViewPending')],response
   ready(c)
  else:
   data=response['structuredContent']
   if not data.get('pending'):
    rows+=data['nodes']
    if data['next'] is None:return dict(data,nodes=rows)
    args.update(start=data['next'],view_id=data['view_id'])
   elif basis=='recorded':args['view_id']=data['view_id']
  assert time.monotonic()<deadline,response
  time.sleep(.002)

def normalized(g):
 return [tuple(n[k] for k in ('parent','name','kind','module_id','mapping_id','address','inclusive','self')) for n in g['nodes']]

def hot_range(path):
 b=path.read_bytes();pe=struct.unpack_from('<I',b,60)[0];opt=pe+24
 table=opt+struct.unpack_from('<H',b,pe+20)[0]
 sections=[struct.unpack_from('<IIII',b,table+40*i+8) for i in range(struct.unpack_from('<H',b,pe+6)[0])]
 def disk(rva):return next(raw+rva-start for virtual,start,size,raw in sections if start<=rva<start+size)
 ex=disk(struct.unpack_from('<I',b,opt+112)[0]);count=struct.unpack_from('<I',b,ex+24)[0]
 funcs,names,ords=map(disk,struct.unpack_from('<III',b,ex+28))
 exports={}
 for i in range(count):
  name_at=disk(struct.unpack_from('<I',b,names+4*i)[0]);name=b[name_at:b.index(0,name_at)].decode()
  ordinal=struct.unpack_from('<H',b,ords+2*i)[0]
  exports[name]=struct.unpack_from('<I',b,funcs+4*ordinal)[0]
 start=exports['uw_hot'];end=min((v for v in exports.values() if v>start),default=start+128)
 return start,end

def check(c,w,report,base,expected,marker,action,usage,wrong):
 lo,hi=hot_range(w/'owned-pe.dll')
 before=usage(c.p.pid)
 cap=action('start_profile',frequency_hz=997,duration_ms=0,user_stack_bytes=8192,user_stack_budget_bytes=8*1024*1024)['capture']
 report['profile_open']=cap
 assert cap['mapping_history']['pe_images']>0,cap
 report['profile_retention_cost']=dict(before=before,after=usage(c.p.pid))
 action('continue');c.stopped('breakpoint',seconds=30)
 cap=action('stop_profile',capture_id=cap['id'])['capture']
 report['profile_final']=cap
 assert cap['stored_samples']>0 and cap['trusted_before_ns'] is None,cap
 samples=[]
 while len(samples)<cap['stored_samples']:
  page=c.inspect('get_profile_samples',capture_id=cap['id'],revision=cap['revision'],start=len(samples),limit=16)
  assert page['samples'],page
  samples+=page['samples']
 def ip(s):
    v=s['sample']['ip'];return int(v,0) if isinstance(v,str) else v
 selected=next((i for i,s in enumerate(samples) if base+lo<=ip(s)<base+hi),None)
 assert selected is not None,(lo,hi,samples)
 result=reconstructed(c,selected);report['saved_unwind']=result;report['saved_sample']=selected
 callers=[int(f['pc'],0) for f in result['frames']]
 wanted=expected.copy()
 if wrong:wanted[0]+=1
 assert callers[2:2+len(wanted)]==wanted,(result,wanted)
 assert all(f['cfi_method'].startswith('windows_') for f in result['frames'][:2+len(wanted)]),result
 # Exercise the borrowed PE asset table in the recorded flame worker as well.
 flame=graph(c)
 report['recorded_flame']=flame
 derived=graph(c,'reconstructed');report['reconstructed_flame']=derived
 assert any(n['name']=='owned-pe.dll!uw_recurse' for n in derived['nodes']),derived
 path=w/'saved.xcap'
 action('save_capture_archive',capture_id=cap['id'],revision=cap['revision'],path=str(path));ready(c)
 offline=Client('control',None,options=['--open-capture',str(path)])
 try:
  origin=ready(offline,opened=True)['recorded_origin'];report['archive_origin']=origin
  assert normalized(graph(offline))==normalized(flame)
  absent=reconstructed(offline,selected)
  assert absent['terminal_reason']=='asset_missing',absent
  root=w/'assets';root.mkdir()
  for asset in origin['images']:
   digest=bytes(asset['identity']['sha256']).hex();source=asset['path']
   assert hashlib.sha256(open(source,'rb').read()).hexdigest()==digest,asset
   shutil.copyfile(source,root/digest)
 finally:offline.close()
 # Neither the live capture nor a resolved archive can reopen the original DLL.
 (w/'owned-pe.dll').rename(w/'retired-pe.dll')
 assert reconstructed(c,selected)==result
 offline=Client('control',None,options=['--open-capture',str(path),'--symbols',str(root)])
 try:
  state=ready(offline,opened=True);resolved=reconstructed(offline,selected)
  report['resolved_unwind']=resolved
  assert resolved==result,(resolved,result)
  assert normalized(graph(offline,'reconstructed'))==normalized(derived)
  assert all(i['status']=='verified' for i in state['recorded_origin']['images']),state
  image=next(i for i in origin['images'] if i['path'].endswith('/owned-pe.dll'))
  asset=root/bytes(image['identity']['sha256']).hex()
  with asset.open('r+b') as f:f.write(b'XX')
  assert reconstructed(offline,selected)==resolved
 finally:offline.close()
 mismatch=Client('control',None,options=['--open-capture',str(path),'--symbols',str(root)])
 try:
  state=ready(mismatch,opened=True);image=next(i for i in state['recorded_origin']['images'] if i['path'].endswith('/owned-pe.dll'))
  assert image['status']=='content_mismatch',image
  refusal=reconstructed(mismatch,selected)
  assert refusal['terminal_reason']=='asset_missing',refusal
  report['mismatch_unwind']=refusal
 finally:mismatch.close()
 report['profile_checks']='runtime callers, raw sample, borrowed flame assets, frozen local assets, typed archive, missing and mismatched assets'
