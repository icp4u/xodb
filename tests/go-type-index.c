#include "check.h"
#include "../src/language/go_type_index.h"
#include <dwarf.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc,char **argv) {
 CHECK(argc==3);
 int fd=open(argv[1],O_RDONLY);CHECK(fd>=0);
 Dwarf *dw=dwarf_begin(fd,DWARF_C_READ);CHECK(dw);
 struct xgo_type_index *index=NULL;
 const char *why=xgo_type_index_create(dw,&index);
 if(!strcmp(argv[2],"bad-form")) {
  CHECK(why && !strcmp(why,"GoDwarfTypeMetadataInvalid") && !index);
 } else {
  CHECK(!why && index);
  CHECK(xgo_type_index_count(index)==(size_t)(!strcmp(argv[2],"wrong") ? 6:5));
  Dwarf_Die die;struct xgo_type_metadata meta;
  why=xgo_type_index_find(index,0,&die);CHECK(why && !strcmp(why,"GoRuntimeTypeMetadataUnavailable"));
  why=xgo_type_index_find(index,65,&die);CHECK(why && !strcmp(why,"GoRuntimeTypeMetadataUnavailable"));
  why=xgo_type_index_find(index,64,&die);
  if(!strcmp(argv[2],"collision")) CHECK(why && !strcmp(why,"GoRuntimeTypeMetadataAmbiguous"));
  else {
   CHECK(!why && !strcmp(dwarf_diename(&die),"int"));
   CHECK(!xgo_type_metadata(&die,&meta));CHECK(meta.kind==2 && meta.runtime_offset==64);
  }
  CHECK(!xgo_type_index_find(index,80,&die));
  CHECK(!xgo_type_metadata(&die,&meta));CHECK(meta.kind==20 && (meta.present&XGO_META_IFACE) && !meta.interface_nonempty);
  CHECK(!xgo_type_index_find(index,88,&die));
  CHECK(!xgo_type_metadata(&die,&meta));CHECK(meta.kind==21 && (meta.present&XGO_META_KEY) && (meta.present&XGO_META_ELEM));
  CHECK(!strcmp(dwarf_diename(&meta.key),"int") && !strcmp(dwarf_diename(&meta.element),"uint"));
 }
 xgo_type_index_free(index);dwarf_end(dw);close(fd);
 CHECK(!strcmp(xgo_type_index_create(NULL,&index),"GoDwarfUnavailable") && !index);
 puts("go-type-index: offsets, aliases, ambiguity, absent/malformed metadata and interface/key/element types pass");
}
