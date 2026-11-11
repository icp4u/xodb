#!/usr/bin/env python3
"""Fast delta/full equivalence, wire-size and protocol-generation checks."""
import copy
import importlib.util
import json
from pathlib import Path
import random
import sys
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tests/helpers'))
from agent_time_wire import Receiver
spec=importlib.util.spec_from_file_location('agent_time',ROOT/'src/profile/agent_time.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)


def document(**fields):
    return {'agent':'synthetic','title':'work','turns':[],'spans':[],'tokens':[],'children':[],
            'live_mode':'append',**fields}


class Delta(unittest.TestCase):
    def roundtrip(self,wire,receiver,doc):
        data=wire.encode(copy.deepcopy(doc))
        expected=copy.deepcopy(doc);expected.pop('source_fingerprint',None)
        self.assertEqual(receiver.accept(json.loads(data)),expected)
        self.assertEqual(json.loads(data)['size'],len(m.wire_json(expected)))
        return data

    def test_insert_before_model_suffix_is_tiny_not_full_snapshot(self):
        spans=[{'activity':'tool:read','start':i,'end':i+1,'detail':'synthetic-'+str(i)} for i in range(2500)]
        spans += [{'activity':'model (inferred)','start':i+0.2,'end':i+0.8,'detail':''} for i in range(2500)]
        doc=document(spans=spans);wire=m.LiveWire();receiver=Receiver()
        full=self.roundtrip(wire,receiver,doc)
        doc['spans'].insert(2500,{'activity':'tool:write','start':2500,'end':2501})
        doc['spans'].append({'activity':'model (inferred)','start':2501,'end':2502})
        delta=self.roundtrip(wire,receiver,doc)
        self.assertLess(len(delta),len(full)//100)
        self.assertNotIn('reset',json.loads(delta))
        self.assertEqual(len(json.loads(delta)['patch']['spans']['ops']),2)

    def test_replacements_deletions_children_and_reset(self):
        doc=document(turns=[{'title':'α "quoted"'}],spans=[{'id':i} for i in range(5)],
                     children=[document(title='child',tokens=[{'weights':{'output':5}}])])
        wire=m.LiveWire();receiver=Receiver();self.roundtrip(wire,receiver,doc)
        doc['spans'][1:3]=[{'id':'replacement'}]
        doc['children'][0]['tokens'][0]['weights']['output']=9
        self.roundtrip(wire,receiver,doc)
        doc['children'].append(document(title='new child'))
        self.roundtrip(wire,receiver,doc)
        doc['live_mode']='rebuild';doc['spans']=[]
        reset=self.roundtrip(wire,receiver,doc)
        self.assertIn('reset',json.loads(reset))
        self.assertEqual(json.loads(wire.encode({'unchanged':True})),{'unchanged':True})
        self.assertEqual(wire.generation,4)

    def test_many_small_changes_match_full_documents(self):
        rng=random.Random(42);wire=m.LiveWire();receiver=Receiver()
        doc=document(spans=[{'value':i%7} for i in range(80)])
        self.roundtrip(wire,receiver,doc)
        for _ in range(100):
            start=rng.randrange(len(doc['spans'])+1)
            end=min(len(doc['spans']),start+rng.randrange(5))
            doc['spans'][start:end]=[{'value':rng.randrange(10)} for _ in range(rng.randrange(5))]
            self.roundtrip(wire,receiver,doc)

    def test_size_limit_and_wrong_generation_are_not_silent(self):
        wire=m.LiveWire();receiver=Receiver();doc=document()
        self.roundtrip(wire,receiver,doc)
        doc['title']='changed'
        with mock.patch.object(m,'MAX_LIVE_WIRE',10):
            with self.assertRaises(ValueError):wire.encode(copy.deepcopy(doc))
        self.assertEqual(wire.generation,1)
        frame=json.loads(wire.encode(doc));frame['base']=0
        with self.assertRaises(AssertionError):receiver.accept(frame)
        self.assertEqual(receiver.generation,1)

    def test_new_child_sends_only_new_data_and_preserves_sibling_order(self):
        children=[document(title=name,spans=[{'detail':name,'id':i} for i in range(1000)]) for name in ('a','c')]
        doc=document(children=children);wire=m.LiveWire();receiver=Receiver()
        full=self.roundtrip(wire,receiver,doc)
        doc['children'].insert(1,document(title='b',spans=[{'detail':'new'}]))
        data=self.roundtrip(wire,receiver,doc)
        self.assertLess(len(data),len(full)//50)
        items=json.loads(data)['patch']['children']['items']
        self.assertEqual(items[0],{'old':0});self.assertEqual(items[2],{'old':1})
        self.assertEqual(items[1]['reset']['title'],'b')
        doc['children'][0]['children'].append(document(title='nested'))
        nested=self.roundtrip(wire,receiver,doc)
        self.assertLess(len(nested),len(full)//50)
        # A same-length metadata update still patches in place after insertion.
        doc['children'][2]['title']='changed';self.roundtrip(wire,receiver,doc)


if __name__=='__main__':unittest.main()
