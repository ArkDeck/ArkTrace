#!/usr/bin/env python3
"""Generate raw native inputs; no expected routes or catalog output."""
import json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[4]
CRATE=ROOT/'rust/crates/arktrace-viewer'
def main():
 keys=[('leftArrow',123,'\uf702'),('rightArrow',124,'\uf703'),('downArrow',125,'\uf701'),('upArrow',126,'\uf700'),('plus',0,'+'),('equal',0,'='),('minus',0,'-'),('underscore',0,'_'),('return',0,'\r'),('lineFeed',0,'\n'),('w',0,'w'),('s',0,'s'),('a',0,'a'),('d',0,'d'),('f',0,'f'),('leftBracket',0,'['),('rightBracket',0,']'),('zero',0,'0'),('escape',0,'\x1b'),('comma',0,','),('period',0,'.'),('m',0,'m')]
 cases=[]
 def add(key,code,chars,mask,extra=None,repeat=False,suffix=''):
  cases.append(dict(id=f'{len(cases):04}-{key}-{mask}-{suffix}',keyCode=code,characters=chars,extraModifier=extra,isRepeat=repeat,normalized=dict(key=key,modifiers={name:bool(mask&(1<<i))for i,name in enumerate(['command','control','option','shift'])},scope='timeline',textInputActive=False)))
 for key,code,chars in keys+[(k,0,c)for k,c in [('unknown','/'),('unknown',''),('unknown','ww'),('unknown','你'),('unknown','é'),('unknown','←'),('unknown','🧭')]]+[(k,0,k.upper())for k in ['w','s','a','d','f','m']]:
  for mask in range(16):add(key,code,chars,mask)
 for key,code,_ in keys[:4]:
  for mask in range(16):add(key,code,'m',mask,suffix='physical-arrow-wins')
 for extra in ['capsLock','function','numericPad','help']:
  for key,code,chars in [keys[i]for i in [0,10,20,21,15]]:
   for repeat in [False,True]:add(key,code,chars,0,extra,repeat,suffix=extra)
 output=CRATE/'tests/fixtures/action-catalog-inputs.json';output.write_text(json.dumps({'schemaVersion':1,'cases':cases},ensure_ascii=False,indent=2)+'\n',encoding='utf-8');print(len(cases),'native inputs')
if __name__=='__main__':main()
