// Synthetic reproduction cases. Run with --json to capture unrounded values.
// Uses only public batch functions, so the same file runs on up/main and #99.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:openstrap_analytics/onehz.dart';
import 'package:openstrap_analytics/src/onehz/util.dart' as u;

// Deterministic differential cases, shared by the tool and parity tests.
List<Map<String, dynamic>> reproductionCases(Map<String, dynamic> base) => [
  for (var i = 0; i < 12; i++) (() {
    final f = jsonDecode(jsonEncode(base)) as Map<String, dynamic>;
    f['hrv']['count'] = i < 6 ? 1800 : 5400;
    f['hrv']['frequency'] = [.17, .7, 2.4, 2.9][i % 4];
    f['hrv']['gapped'] = i.isOdd;
    f['spectral']['origin'] = i.isEven ? 1800000000.0 : 0.0;
    f['spectral']['frequency'] = .037 + i * .019;
    f['rr']['run'] = [1, 16, 30, 31, 32, 33][i % 6];
    f['cosinor']['step'] = .31 + i * .11;
    f['load']['count'] = 30 + i * 7;
    f['zones']['count'] = 50 + i * 11;
    f['circadian']['days'] = 1 + i % 4;
    return f;
  })()
];

Map<String, Object?> reproduce(Map<String, dynamic> f) {
  final out = <String, Object?>{};
  final r = f['rr'] as Map<String, dynamic>;
  final rr = [for (var i=0;i<(r['before'] as int);i++) (r['normal'] as num).toDouble(),
    for (var i=0;i<(r['run'] as int);i++) (r['artifact'] as num).toDouble(),
    for (var i=0;i<(r['after'] as int);i++) (r['normal'] as num).toDouble()];
  final clean = correctRr(rr);
  out['rr'] = [clean.nn.length, clean.droppedCount, clean.correctedCount];
  final s=f['spectral'] as Map<String,dynamic>;
  final t=[for(var i=0;i<(s['count'] as int);i++) (s['origin'] as num).toDouble()+i*(s['step'] as num)];
  final y=[for(var i=0;i<t.length;i++) 900+30*math.sin(i*.71)+7*math.cos(i*.19)];
  out['spectral']=u.lombScargle(t,y,[(s['frequency'] as num).toDouble()])!.spectrum.single.psd;
  final c=f['cosinor'] as Map<String,dynamic>;
  final ct=[for(var i=0;i<(c['count'] as int);i++) i*(c['step'] as num).toDouble()];
  final cy=[for(var i=0;i<ct.length;i++) 60+2*math.cos(2*math.pi*ct[i]/24)+.07*(i%7)];
  final cv=cosinor(ct,cy).value!;
  out['cosinor']=[cv.mesor,cv.amplitude,cv.r2,cv.amplitudeP];
  final n=f['near_singular'] as Map<String,dynamic>;
  final nt=[for(var i=0;i<(n['count'] as int);i++) (n['origin'] as num).toDouble()+i*(n['step'] as num)];
  out['near_singular']=cosinor(nt,[for(var i=0;i<nt.length;i++) 60+i*.01]).present;
  final nn=[for(var i=0;i<(f['hrv']['count'] as int);i++) 900+30*math.sin(i*((f['hrv']['frequency'] as num?)?.toDouble() ?? .17))+5*math.cos(i*.071)];
  var now=0.0;
  final times=[for(var i=0;i<nn.length;i++) now+=nn[i]+(f['hrv']['gapped']==true && i>0 && i%400==0 ? 10000 : 0)];
  final hv=hrvTime(nn,nnTimesMs:times).value!;
  out['hrv']=[hv.rmssd,hv.sdnn,hv.sdann,hv.sdnnIndex,hv.diffAcf1];
  try {
    final bad=[...times]..[times.length-1]=double.infinity;
    out['nonfinite']=hrvTime(nn,nnTimesMs:bad).present;
  } catch(e) { out['nonfinite']='throws'; }
  final load=[for(var i=0;i<(f['load']['count'] as int);i++) 80.1+(i%13)*3.17];
  out['trimp']=banisterTrimp(load,restingHr:60,maxHr:190,sex:Sex.male).value;
  final lv=ctlAtlTsb(load).value!;
  out['ctl']=[lv.ctl,lv.atl,lv.tsb];
  final z=[for(var i=0;i<(f['zones']['count'] as int);i++) HrSample(i*1000.1,120.0)];
  out['zones']=HeartRateZones.timeInZone(z,HeartRateZones.zonesFromMaxHr(190))!.seconds;
  final x=[for(var i=0;i<(f['circadian']['days'] as int)*(f['circadian']['epochs'] as int);i++) 1.1+(i%24)*.13+(i%3)*1e-14];
  final ci=circadianNonparametric(x,f['circadian']['epochs'] as int).value!;
  out['circadian']=[ci.interdailyStability,ci.intradailyVariability,ci.m10,ci.l5,ci.m10StartEpoch,ci.l5StartEpoch];
  final ir=irregularBeatScreen([800,900,1000,1100,700,850,900,1000].map((v)=>v.toDouble()).toList(),
    nnTimesMs:[800,1700,2700,3800,14500,15350,16250,17250],minBeats:4).value!;
  out['irregular_gap']=[ir.sd1,ir.pnnPct];
  return out;
}
void main(List<String> args) {
  final f=jsonDecode(File('test/fixtures/output_changes.json').readAsStringSync()) as Map<String,dynamic>;
  if(args.contains('--corpus-json')) { print(jsonEncode([for(final c in reproductionCases(f)) reproduce(c)])); return; }
  final values=reproduce(f);
  if(args.contains('--json')) { print(jsonEncode(values)); return; }
  print('| Change | up/main 3a7ca34 | Current batch |');
  print('|---|---|---|');
  final old=f['old'] as Map<String,dynamic>;
  for(final entry in values.entries) {
    print('| ${entry.key} | ${old[entry.key]} | ${entry.value} |');
  }
}
