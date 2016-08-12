#!/bin/bash -ex

PKG="lwt,vchan,vchan.lwt,xenstore,xenstore_transport,uuidm,uri,xenlight,xenctrl,ipaddr"
OPT="-linkpkg"
OBJ="libxld"
SRC="gk_msg.mli gk_msg.ml gk_xenstore.ml gk_vm_state.ml gk_options.ml gk_libxl_backend.ml gk_vm_stop_mode.ml gk_backends.mli gk_libxld.ml"

BUILD="*.cmi *.cmx *.o"
BUILDDIR="_mbuild"

case $1 in
"build")
  echo "build..."
  ocamlfind ocamlopt -package $PKG $OPT -o $OBJ $SRC

  if [[ -d $BUILDDIR ]]; then
      rm $BUILDDIR/* || true
  else
      mkdir $BUILDDIR
  fi

  mv $BUILD $BUILDDIR
  ;;

"clean")
  echo "clean..."

  rm $BUILD $OBJ || true

  if [[ -d $BUILDDIR ]]; then
      rm $BUILDDIR/* || true
      rmdir $BUILDDIR
  fi
  ;;
*)
  echo "unknow subcommand [" $1 "]"
  ;;
esac
