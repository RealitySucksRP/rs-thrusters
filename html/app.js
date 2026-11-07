'use strict';
const $ = id => document.getElementById(id);
const hud=$('hud'), panel=$('settings');
const resource = (typeof GetParentResourceName==='function') ? GetParentResourceName() : 'rs-thrusters';
let enabled=false;
const fxColorNames=['solid','slow','fast','overrun'];
const jetRows = new Map();
function showJets(jets){
  for(const jet of jets){
    if(!jetRows.has(jet.name)){
      const row=document.createElement('div'), label=document.createElement('span'), value=document.createElement('b');
      label.textContent=jet.name.replaceAll('_',' ').toUpperCase();
      row.append(label,value); $('jets').append(row); jetRows.set(jet.name,{row,value});
    }
    const {row,value}=jetRows.get(jet.name);
    value.textContent=String(jet.rpm).padStart(5,'0')+' / '+String(jet.thrust).padStart(2,'0')+'%';
    row.classList.toggle('firing',jet.thrust>0);
  }
}
function send(name,data={}){
  return fetch(`https://${resource}/${name}`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(data)}).catch(()=>{});
}
function settings(){
  return {mode:$('flightMode').value,hoverStyle:$('hoverStyle').value,controllerPitchEnabled:$('stickPitch').checked,landingAssist:$('landing').checked,hudVisible:$('showHud').checked,chaseEnabled:$('chaseCam').checked,thrustOutput:Number($('output').value)/100,hoverTarget:Number($('target').value),tankDuration:Number($('tankDuration').value),fxStyle:$('fxStyle').value,fxColors:Object.fromEntries(fxColorNames.map(name=>[name,$('fx-'+name).value]))};
}
function close(){ panel.classList.add('hidden'); send('settings',settings()); send('close'); }
$('close').addEventListener('click',close); $('done').addEventListener('click',close);
$('flightMode').addEventListener('change',()=>send('settings',settings()));
$('stickPitch').addEventListener('change',()=>send('settings',settings()));
$('landing').addEventListener('change',()=>send('settings',settings()));
$('showHud').addEventListener('change',()=>send('settings',settings()));
$('output').addEventListener('input',()=>{$('outValue').textContent=$('output').value+'%';send('settings',settings());});
$('target').addEventListener('input',()=>{$('targetValue').textContent=Number($('target').value).toFixed(1)+'m';send('settings',settings());});
for(const id of ['fxStyle', ...fxColorNames.map(name=>'fx-'+name)]){
  $(id).addEventListener('change',()=>send('settings',settings()));
}
function showTankDuration(){
  const seconds=Number($('tankDuration').value);
  $('tankValue').textContent=Math.floor(seconds/60)+'m '+(seconds%60)+'s';
}
$('tankDuration').addEventListener('input',showTankDuration);
$('tankDuration').addEventListener('change',()=>send('settings',settings()));
window.addEventListener('keydown', e=>{if(e.key==='Escape' && !panel.classList.contains('hidden'))close();});
window.addEventListener('message',ev=>{
 const d=ev.data||{};
 if(d.type==='hud'){
  hud.classList.toggle('hidden', !d.visible);
  if(!d.visible)return;
  enabled=!!d.enabled;
  $('state').textContent=enabled?'ACTIVE':'STANDBY';$('state').classList.toggle('active',enabled);
  const gas=Math.max(0,Math.min(100,Math.round(100*(Number(d.pressure)||0)/(Number(d.capacity)||100))));
  $('pressure').textContent=gas+'%';$('gasfill').style.width=gas+'%';$('gasfill').classList.toggle('low',gas<20);
  $('altitude').innerHTML=Math.max(0,Number(d.height)||0).toFixed(1)+'<em>m</em>';
  $('thrust').textContent=Math.min(100,Math.round((Number(d.thrust)||0)*100))+'%';
  $('stability').textContent=d.warning||'STANDBY';
  $('stability').dataset.severity=d.severity||'ok';
  $('attitude').textContent=Math.round(d.tilt||0)+'° · '+Math.round(d.rotationRate||0)+'°/s';
  showJets(d.nozzles||[]);
  $('mode').textContent=String(d.mode||'assisted').toUpperCase();
  $('hover').textContent=d.hover?'HOVER ON':'HOVER OFF';
  $('land').textContent=d.landingAssist?'LANDING ON':'LANDING OFF';
 }
 if(d.type==='panel'){
  panel.classList.toggle('hidden', !d.open);
  if(d.open){
   $('fxStyle').value=d.fxStyle||'stock';
   for(const name of fxColorNames){
    if(d.fxColors?.[name]) $('fx-'+name).value=d.fxColors[name];
   }
   const slider=$('tankDuration');
   slider.min=d.tankMin;
   slider.max=d.tankMax;
   slider.value=d.tankDuration;
   slider.disabled=!d.consumptionEnabled||!d.allowTankDuration;
   $('tankHelp').textContent=!d.consumptionEnabled?'Unlimited fuel for testing.':
     d.allowTankDuration?'Time at full lift output. Other maneuvers use gas at different rates.':
     'Tank duration is set by the server.';
   if(d.consumptionEnabled) showTankDuration();
   else $('tankValue').textContent='UNLIMITED';
  }
  if(d.open){$('flightMode').value=d.mode||'assisted';$('hoverStyle').value=d.hoverStyle||'helicopter';$('stickPitch').checked=d.controllerPitchEnabled===true;$('landing').checked=!!d.landingAssist;$('showHud').checked=!!d.hudVisible;$('chaseCam').checked=!!d.chaseEnabled;$('output').value=Math.round((Number(d.thrustOutput)||1)*100);$('target').value=Number(d.hoverTarget)||3.2;$('outValue').textContent=$('output').value+'%';$('targetValue').textContent=Number($('target').value).toFixed(1)+'m';}
 }
});
