"""Independent test-only receiver for the live delta protocol."""
import copy


class Receiver:
    def __init__(self):
        self.document=None
        self.generation=0

    def accept(self,frame):
        if frame.get('unchanged') or frame.get('failure'):return frame
        assert frame['wire']==1 and frame['generation']>self.generation
        assert frame['size']<=64*1024*1024
        if 'reset' in frame:document=copy.deepcopy(frame['reset'])
        else:
            assert frame['base']==self.generation and frame['generation']==self.generation+1
            document=self.patch(self.document,frame['patch'])
        self.document=document
        self.generation=frame['generation']
        return document

    @classmethod
    def patch(cls,old,change):
        result=copy.deepcopy(change['meta'])
        for name in ('turns','spans','tokens'):
            rows=copy.deepcopy(old.get(name,[]))
            if name in change:
                edit=change[name];assert edit['length']==len(rows)
                cursor=0
                for start,end,items in edit['ops']:
                    assert cursor<=start<=end<=len(rows);cursor=end
                for start,end,items in reversed(edit['ops']):rows[start:end]=copy.deepcopy(items)
            result[name]=rows
        children=copy.deepcopy(old.get('children',[]))
        if 'children' in change:
            edits=change['children'];assert edits['length']==len(children)
            if 'items' in edits:
                old=children;children=[];seen=set()
                for item in edits['items']:
                    if 'old' in item:
                        index=item['old'];assert 0<=index<len(old) and index not in seen
                        seen.add(index);children.append(old[index])
                    else:children.append(copy.deepcopy(item['reset']))
            else:
                for index,patch in edits['patches']:children[index]=cls.patch(children[index],patch)
        result['children']=children
        return result
