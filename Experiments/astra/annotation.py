#!/usr/bin/env python3
"""Extract native dev-capture video frames serially and create a local blinded label UI."""
import argparse,collections,json,os,pathlib,random,subprocess
HERE=pathlib.Path(__file__).resolve().parent

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--extract',action='store_true');a=ap.parse_args()
    out=HERE/'results';samples=json.loads((out/'samples.json').read_text());groups=collections.defaultdict(list)
    for s in samples:groups[s['directory']].append(s)
    frames=out/'annotation_frames';frames.mkdir(exist_ok=True);items=[];checks=[]
    for directory,ss in groups.items():
        ss.sort(key=lambda s:s['timestamp']);video=pathlib.Path(directory)/'camera.mp4'
        if a.extract:
            probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','v:0','-show_frames','-show_entries','frame=best_effort_timestamp_time','-of','json',str(video)]))
            pts=[float(f['best_effort_timestamp_time']) for f in probe['frames']]
            assert len(pts)==len(ss),(video,len(pts),len(ss))
            error=max(abs(t-s['videoPTSValue']/s['videoPTSTimescale']) for t,s in zip(pts,ss));assert error<.002,error
            temp=frames/f"epoch{ss[0]['epoch']}";temp.mkdir(exist_ok=True)
            subprocess.run(['ffmpeg','-v','error','-threads','1','-i',str(video),'-fps_mode','passthrough','-threads','1','-q:v','3','-y',str(temp/'%06d.jpg')],check=True)
            for i,s in enumerate(ss,1):(temp/f'{i:06d}.jpg').replace(frames/f"B{s['epoch']}_{s['frameID']}.jpg")
            temp.rmdir();checks.append(dict(epoch=ss[0]['epoch'],decodedFrames=len(pts),maximumPTSDiscrepancySeconds=error))
        for s in ss:items.append(dict(id=f"B{s['epoch']}_{s['frameID']}",epoch=s['epoch'],frameID=s['frameID'],timestamp=s['timestamp'],pts=s['videoPTSValue']/s['videoPTSTimescale'],video=os.path.relpath(video,out),image=f"annotation_frames/B{s['epoch']}_{s['frameID']}.jpg"))
    items.sort(key=lambda s:(s['epoch'],s['timestamp']))
    random.Random(0).shuffle(items)
    html='''<!doctype html><meta charset="utf-8"><title>PRTS 独立标注</title><style>body{font:16px system-ui;max-width:1100px;margin:24px auto;background:#111;color:#eee}button,input,select{font:inherit;padding:8px;margin:4px}img{max-height:65vh;max-width:60vw;object-fit:contain;image-orientation:none}video{max-width:35vw}section{display:flex;gap:16px}small{color:#bbb}</style>
<h1>正前方身体带内的障碍标注</h1><p>不显示算法结论。身体带总宽 0.60 m，脚前水平距离 ≤1 m；同时标 ≤0.5 m。看不清、不能确定距离、手机方向与身体朝向不一致时选不确定。仅凭图片不能确定真实米制距离。</p>
<label>标注员 <input id="who" placeholder="独立编号"></label><select id="choose"></select><button onclick="step(-1)">上一帧</button><button onclick="step(1)">下一帧</button><button onclick="exportData()">导出我的 JSON</button><p id="position"></p>
<section><img id="frame"><div><video id="video" controls muted preload="none"></video><br><button onclick="contextVideo()">查看前后视频</button><p>1m 内 <select id="one"><option value="">未标</option><option>yes</option><option>no</option><option>uncertain</option><option>not_visible</option></select></p><p>0.5m 内 <select id="half"><option value="">未标</option><option>yes</option><option>no</option><option>uncertain</option><option>not_visible</option></select></p><p>米制距离依据 <select id="certainty"><option value="">未标</option><option>independent_measurement</option><option>visual_estimate</option><option>uncertain</option></select></p><p><input id="kind" placeholder="障碍类别"></p><p><input id="note" placeholder="可见性/距离依据/身体朝向/事件号"></p><button onclick="save();step(1)">保存并下一帧</button></div></section>
<small>独立标注文件由第三人合并裁决；不确定不得填 no。状态存于本浏览器 localStorage，结束前务必导出。本页面不联网。</small>
<script>const items=ITEMS;let index=0;let labels=JSON.parse(localStorage.getItem('astra_labels')||'{}');const $=id=>document.getElementById(id);items.forEach((s,i)=>{const o=document.createElement('option');o.value=i;o.textContent=s.id;$('choose').append(o)});function key(){return $('who').value+'|'+items[index].id}function load(){const s=items[index];$('choose').value=index;$('frame').src=s.image;$('position').textContent=`${index+1}/${items.length} ${s.id} AR ${s.timestamp.toFixed(3)}s 视频 ${s.pts.toFixed(3)}s`;$('video').pause();const v=labels[key()]||{};for(const n of ['one','half','certainty','kind','note'])$(n).value=v[n]||''}function save(){if(!$('who').value)return;labels[key()]={...items[index],annotator:$('who').value,...Object.fromEntries(['one','half','certainty','kind','note'].map(n=>[n,$(n).value]))};localStorage.setItem('astra_labels',JSON.stringify(labels))}function step(n){save();index=Math.max(0,Math.min(items.length-1,index+n));load()}function contextVideo(){const s=items[index];$('video').src=s.video;$('video').currentTime=Math.max(0,s.pts-2);$('video').play()}$('choose').onchange=()=>{save();index=+$('choose').value;load()};$('who').onchange=load;function exportData(){save();const data=Object.values(labels).filter(x=>x.annotator===$('who').value);const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([JSON.stringify(data,null,2)],{type:'application/json'}));a.download='labels-'+$('who').value+'.json';a.click();URL.revokeObjectURL(a.href)}load();</script>'''
    html=html.replace('<img id="frame">','<canvas id="frame" style="width:360px;height:480px;max-width:45vw;object-fit:contain"></canvas>')
    html=html.replace("$('frame').src=s.image;", "$('frame').getContext('2d').clearRect(0,0,$('frame').width,$('frame').height);const im=new Image();im.onload=()=>{if(items[index].id!==s.id)return;const c=$('frame');c.width=im.height;c.height=im.width;const ctx=c.getContext('2d');ctx.translate(c.width,0);ctx.rotate(Math.PI/2);ctx.drawImage(im,0,0)};im.src=s.image;")
    (out/'annotation.html').write_text(html.replace('ITEMS',json.dumps(items,ensure_ascii=False)))
    if a.extract:(out/'video_check.json').write_text(json.dumps(checks,indent=2))
    print(json.dumps(dict(frames=len(items),checks=checks,page=str(out/'annotation.html')),indent=2))

if __name__=='__main__':main()
