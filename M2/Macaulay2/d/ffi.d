use system;
use common;
use hashtables;
use evaluate;

header "#include <dlfcn.h>
	#include <ffi.h>
	/* FFI_BAD_ARGTYPE not introduced until libffi 3.4 in 2021 */
	#ifndef FFI_BAD_ARGTYPE
	  #define FFI_BAD_ARGTYPE 3
	#endif
	#include <M2mem.h>";

-- ffi_get_struct_offsets not introduced until libffi 3.3 in 2019
-- so we provide an alternate implementation
header "
#ifndef HAVE_FFI_GET_STRUCT_OFFSETS
#define FFI_ALIGN(v, a)  (((((size_t) (v))-1) | ((a)-1))+1)

ffi_status
ffi_get_struct_offsets(ffi_abi abi, ffi_type *struct_type, size_t *offsets)
{
  ffi_cif cif;
  ffi_status status;
  ffi_type **ptr;
  size_t size;

  status = ffi_prep_cif(&cif, abi, 0, struct_type, NULL);
  if (status != FFI_OK)
    return status;

  ptr = &(struct_type->elements[0]);
  size = 0;

  while ((*ptr) != NULL) {
      size = FFI_ALIGN(size, (*ptr)->alignment);
      *offsets++ = size;
      size += (*ptr)->size;
      ptr++;
  }

  return FFI_OK;
}
#endif
";

voidPointerOrNull := voidPointer or null;
toExpr(x:voidPointer):Expr := Expr(pointerCell(x));
WrongArgPointer():Expr := WrongArg("a pointer");
WrongArgPointer(n:int):Expr := WrongArg(n, "a pointer");
setupconst("nullPointer", toExpr(nullPointer()));

getMem(n:int):voidPointer := Ccode(voidPointer, "getmem(", n, ")");
getMemAtomic(n:int):voidPointer := Ccode(voidPointer, "getmem_atomic(", n, ")");
pointerSize := Ccode(int, "sizeof(void *)");

dlerror0():Expr:= buildErrorPacket(tostring(Ccode(charstar, "dlerror()")));

dlopen0(e:Expr):Expr:=
    when e
    is s:stringCell do (
	r := Ccode(voidPointerOrNull,
	    "dlopen(", tocharstar(s.v), ", RTLD_LAZY)");
	when r
	is null do dlerror0()
	is handle:voidPointer do toExpr(handle))
    else WrongArgString();
setupfun("dlopen", dlopen0);

dlsym0(e:Expr):Expr :=
    when e
    is y:stringCell do (
	r := Ccode(voidPointerOrNull,
	    "dlsym(RTLD_DEFAULT, ", tocharstar(y.v), ")");
	when r
	is null do dlerror0()
	is addr:voidPointer do toExpr(addr))
    is a:Sequence do
	if length(a) != 2 then WrongNumArgs(1,2)
	else when a.0
	    is x:pointerCell do when a.1
		is y:stringCell do (
		    r := Ccode(voidPointerOrNull,
			"dlsym(", x.v, ", ", tocharstar(y.v), ")");
		    when r
		    is null do dlerror0()
		    is addr:voidPointer do toExpr(addr))
		else WrongArgString(2)
	    else WrongArgPointer(1)
    else WrongArg("a string or a pointer and a string");
setupfun("dlsym", dlsym0);

ffiTypeVoid := Ccode(voidPointer, "&ffi_type_void");
ffiOk := Ccode(int, "FFI_OK");

ffiTypeSize(e:Expr):Expr := (
    when e
    is x:pointerCell do toExpr(Ccode(int, "((ffi_type *)", x.v, ")->size"))
    else WrongArgPointer());
setupfun("ffiTypeSize", ffiTypeSize);

ffiError(r:int):Expr:=
    if r == Ccode(int, "FFI_BAD_TYPEDEF")
    then buildErrorPacket("libffi: bad typedef")
    else if r == Ccode(int, "FFI_BAD_ABI")
    then buildErrorPacket("libffi: bad ABI")
    else if r == Ccode(int, "FFI_BAD_ARGTYPE")
    then buildErrorPacket("libffi: bad argtype")
    else buildErrorPacket("libffi: unknown");

ffiPrepCif(e:Expr):Expr :=
    when e
    is a:Sequence do
	if length(a) != 2 then WrongNumArgs(2)
	else when a.0
	    is x:pointerCell do when a.1
		is y:List do (
		    argtypes := new array(voidPointer) len length(y.v) at i
			do provide when y.v.i is z:pointerCell do z.v
			    else ffiTypeVoid;
		    cif := Ccode(voidPointer, "getmem(sizeof(ffi_cif))");
		    r := Ccode(int, "ffi_prep_cif((ffi_cif *)", cif,
			", FFI_DEFAULT_ABI, ",
			argtypes, "->len, ",
			"(ffi_type *) ", x.v, ", ",
			"(ffi_type **) ", argtypes, "->array)");
		    if r != ffiOk then ffiError(r)
		    else toExpr(cif))
		else WrongArg(2, "a list")
	    else WrongArgPointer(1)
    else WrongNumArgs(2);
setupfun("ffiPrepCif", ffiPrepCif);

ffiPrepCifVar(e:Expr):Expr :=
    when e
    is a:Sequence do
	if length(a) != 3 then WrongNumArgs(3)
	else when a.0
	    is n:ZZcell do when a.1
		is x:pointerCell do when a.2
		    is y:List do (
			argtypes := new array(voidPointer) len length(y.v) at i
				do provide when y.v.i is z:pointerCell do z.v
				else ffiTypeVoid;
			cif := Ccode(voidPointer, "getmem(sizeof(ffi_cif))");
			r := Ccode(int, "ffi_prep_cif_var((ffi_cif *)", cif,
			    ", FFI_DEFAULT_ABI, ",
			    toInt(n), ", ",
			    argtypes, "->len, ",
			    "(ffi_type *) ", x.v, ", ",
			    "(ffi_type **) ", argtypes, "->array)");
			if r != ffiOk then ffiError(r)
			else toExpr(cif))
		    else WrongArg(3, "a list")
		else WrongArgPointer(2)
	    else WrongArgZZ(1)
	else WrongNumArgs(3);
setupfun("ffiPrepCifVar", ffiPrepCifVar);

-- fix return value on big-endian systems, since integer types are widened
-- to system register size
endianAdjust(ptr:voidPointer, rtype:voidPointer):voidPointer:= (
    if Ccode(int, "__BYTE_ORDER__") == Ccode(int, "__ORDER_LITTLE_ENDIAN__")
    then ptr
    else (
	offset := Ccode(int,
	    "sizeof(ffi_arg) - ((ffi_type *)", rtype,")->size");
	if (Ccode(int, "((ffi_type *)", rtype, ")->type") ==
	    Ccode(int, "FFI_TYPE_FLOAT") || offset <= 0)
	then ptr
	else Ccode(voidPointer, ptr, " + ", offset)));

ffiCall(e:Expr):Expr :=
    when e
    is a:Sequence do
	if length(a) != 4 then WrongNumArgs(4)
	else when a.0
	    is cif:pointerCell do when a.1
		is fn:pointerCell do when a.2
		    is n:ZZcell do when a.3
			is z:List do (
			    rvalue := getMem(toInt(n));
			    avalues := new array(voidPointer)
				len length(z.v) at i
				    do provide when z.v.i is p:pointerCell
					do p.v
					else nullPointer();
			    Ccode(void, "ffi_call((ffi_cif *)", cif.v, ", ",
				fn.v, ", ",
				rvalue, ", ",
				avalues, "->array)");
			    toExpr(endianAdjust(rvalue, Ccode(voidPointer,
					"((ffi_cif *)", cif.v, ")->rtype"))))
			else WrongArg(4, "a list")
		    else WrongArgZZ(3)
		else WrongArgPointer(2)
	    else WrongArgPointer(1)
    else WrongNumArgs(4);
setupfun("ffiCall", ffiCall);

---------------
-- void type --
---------------
setupconst("ffiVoidType", toExpr(Ccode(voidPointer, "&ffi_type_void")));

-------------------
-- integer types --
-------------------

-- returns pointer to ffi_type object for given integer type
-- input: (n:ZZ, signed:Boolean)
-- n = number of bits (or 0 for mpz_t)
ffiIntegerType(e:Expr):Expr := (
    when e
    is a:Sequence do (
	if length(a) == 2 then (
	    when a.0
	    is n:ZZcell do (
		if !isInt(n)
		then WrongArgSmallInteger(1)
		else if isZero(n.v)
		then toExpr(Ccode(voidPointer, "&ffi_type_pointer"))
		else when a.1
		is signed:Boolean do (
		    bits := toInt(n);
		    if signed.v then (
			if bits == 8
			then toExpr(Ccode(voidPointer, "&ffi_type_sint8"))
			else if bits == 16
			then toExpr(Ccode(voidPointer, "&ffi_type_sint16"))
			else if bits == 32
			then toExpr(Ccode(voidPointer, "&ffi_type_sint32"))
			else if bits == 64
			then toExpr(Ccode(voidPointer, "&ffi_type_sint64"))
			else buildErrorPacket("expected 8, 16, 32, or 64 bits"))
		    else (
			if bits == 8
			then toExpr(Ccode(voidPointer, "&ffi_type_uint8"))
			else if bits == 16
			then toExpr(Ccode(voidPointer, "&ffi_type_uint16"))
			else if bits == 32
			then toExpr(Ccode(voidPointer, "&ffi_type_uint32"))
			else if bits == 64
			then toExpr(Ccode(voidPointer, "&ffi_type_uint64"))
			else buildErrorPacket("expected 8, 16, 32, or 64 bits"))
		    )
		else WrongArgBoolean(2))
	    else WrongArgZZ(1))
	else WrongNumArgs(2))
    else WrongNumArgs(2));
setupfun("ffiIntegerType", ffiIntegerType);

-- returns pointer to integer object with given value
-- inputs (x:ZZ, y:ZZ, signed:Boolean)
-- x = value
-- y = number of bits (or 0 for mpz_t)
ffiIntegerAddress(e:Expr):Expr := (
    when e
    is a:Sequence do (
	if length(a) == 3 then (
	    when a.0
	    is x:ZZcell do (
		when a.1
		is y:ZZcell do (
		    if !isInt(y)
		    then WrongArgSmallInteger(2)
		    else if isZero(y.v) then (
			z := newZZmutable();
			set(z, x.v);
			ptr := getMem(pointerSize);
			Ccode(void, "*(mpz_ptr *)", ptr, " = ", z);
			Ccode(void, "GC_REGISTER_FINALIZER(", ptr, ", ",
			    "(GC_finalization_proc)mpz_clear, ", z, ", 0, 0)");
			toExpr(ptr))
		    else when a.2
		    is signed:Boolean do (
			bits := toInt(y);
			ptr := getMemAtomic(bits / 8);
			if signed.v then (
			    if bits == 8
			    then Ccode(void, "*(int8_t *)", ptr, " = ",
				toInt(x))
			    else if bits == 16
			    then Ccode(void, "*(int16_t *)", ptr, " = ",
				toInt(x))
			    else if bits == 32
			    then Ccode(void, "*(int32_t *)", ptr, " = ",
				toLong(x))
			    else if bits == 64
			    then Ccode(void, "*(int64_t *)", ptr, " = ",
				toInt64(x))
			    else return buildErrorPacket(
				"expected 8, 16, 32, or 64 bits");
			    toExpr(ptr))
			else (
			    if bits == 8
			    then Ccode(void, "*(uint8_t *)", ptr, " = ",
				toUInt(x))
			    else if bits == 16
			    then Ccode(void, "*(uint16_t *)", ptr, " = ",
				toUInt(x))
			    else if bits == 32
			    then Ccode(void, "*(uint32_t *)", ptr, " = ",
				toULong(x))
			    else if bits == 64
			    then Ccode(void, "*(uint64_t *)", ptr, " = ",
				toUInt64(x))
			    else return buildErrorPacket(
				"expected 8, 16, 32, or 64 bits");
			    toExpr(ptr)))
		    else WrongArgBoolean(3))
		else WrongArgZZ(2))
	    else WrongArgZZ(1))
	else WrongNumArgs(3))
    else WrongNumArgs(3));
setupfun("ffiIntegerAddress", ffiIntegerAddress);

-- returns value (as ZZ) of integer object given its address
-- inputs: (x:Pointer, y:ZZ, signed:ZZ)
-- x = pointer to integer object
-- y = number of bits (or 0 for mpz_t)
ffiIntegerValue(e:Expr):Expr := (
    when e
    is a:Sequence do (
	if length(a) == 3 then (
	    when a.0
	    is x:pointerCell do (
		when a.1
		is y:ZZcell do (
		    if !isInt(y)
		    then WrongArgSmallInteger(2)
		    else if isZero(y.v)
		    then toExpr(moveToZZ(Ccode(ZZmutable, "*(mpz_ptr*)", x.v)))
		    else when a.2
		    is signed:Boolean do (
			bits := toInt(y);
			if signed.v then (
			    if bits == 8
			    then toExpr(Ccode(int8_t, "*(int8_t *)", x.v))
			    else if bits == 16
			    then toExpr(Ccode(int16_t, "*(int16_t *)", x.v))
			    else if bits == 32
			    then toExpr(Ccode(int32_t, "*(int32_t *)", x.v))
			    else if bits == 64
			    then toExpr(Ccode(int64_t, "*(int64_t *)", x.v))
			    else buildErrorPacket(
				"expected 8, 16, 32, or 64 bits"))
			else (
			    if bits == 8
			    then toExpr(Ccode(uint8_t, "*(uint8_t *)", x.v))
			    else if bits == 16
			    then toExpr(Ccode(uint16_t, "*(uint16_t *)", x.v))
			    else if bits == 32
			    then toExpr(Ccode(uint32_t, "*(uint32_t *)", x.v))
			    else if bits == 64
			    then toExpr(Ccode(uint64_t, "*(uint64_t *)", x.v))
			    else buildErrorPacket(
				"expected 8, 16, 32, or 64 bits")))
		    else WrongArgBoolean(3))
		else WrongArgZZ(2))
	    else WrongArgPointer(1))
	else WrongNumArgs(3))
    else WrongNumArgs(3));
setupfun("ffiIntegerValue", ffiIntegerValue);

----------------
-- real types --
----------------

-- returns pointer to ffi_type object for given real number type
-- input: n:ZZ (0 = mpfr_t, 32 = float, 64 = double)
ffiRealType(e:Expr):Expr := (
    when e
    is n:ZZcell do (
	if !isInt(n) then return WrongArgSmallInteger();
	bits := toInt(n);
	if bits == 0 then toExpr(Ccode(voidPointer, "&ffi_type_pointer"))
	else if bits == 32 then toExpr(Ccode(voidPointer, "&ffi_type_float"))
	else if bits == 64 then toExpr(Ccode(voidPointer, "&ffi_type_double"))
	else buildErrorPacket("expected 32 or 64 bits"))
    else WrongArgZZ());
setupfun("ffiRealType", ffiRealType);

-- returns pointer to real number object with given value
-- inputs: (x:RR, y:ZZ)
-- x = value
-- y = type (0 = mpfr_t, 32 = float, 64 = double)
ffiRealAddress(e:Expr):Expr := (
    when e
    is a:Sequence do (
	if length(a) == 2 then (
	    when a.0
	    is x:RRcell do (
		when a.1
		is y:ZZcell do (
		    if !isInt(y) then return WrongArgSmallInteger();
		    bits := toInt(y);
		    if bits == 0 then (
			z := newRRmutable(precision(x.v));
			Ccode(void, "mpfr_set(", z, ", ", x.v, ", MPFR_RNDN)");
			ptr := getMem(pointerSize);
			Ccode(void, "*(mpfr_ptr *)", ptr, " = ", z);
			-- TODO: we get segfaults during garbage collection
			-- if the following is uncommented
			-- Ccode(void, "GC_REGISTER_FINALIZER(", ptr, ", ",
			--  "(GC_finalization_proc)mpfr_clear, ", z, ", 0, 0)");
			toExpr(ptr))
		    else if bits == 32 || bits == 64 then (
			ptr := getMemAtomic(bits / 8);
			if bits == 32
			then (
			    z := toFloat(x);
			    Ccode(void, "*(float *)", ptr, " = ", z))
			else if bits == 64
			then (
			    z := toDouble(x);
			    Ccode(void, "*(double *)", ptr, " = ", z));
			toExpr(ptr))
		    else return buildErrorPacket("expected 0, 32, or 64"))
		else WrongArgZZ(2))
	    else WrongArgRR(1))
	else WrongNumArgs(2))
    else WrongNumArgs(2));
setupfun("ffiRealAddress", ffiRealAddress);

-- returns value (as RR) of real number object given its address
-- inputs: (x:Pointer, y:ZZ)
-- x = pointer to real number object
-- y = type (0 = mpfr_t, 32 = float, 64 = double)
ffiRealValue(e:Expr):Expr := (
    when e
    is a:Sequence do (
	if length(a) == 2 then (
	    when a.0
	    is x:pointerCell do (
		when a.1
		is y:ZZcell do (
		    if !isInt(y) then return WrongArgSmallInteger();
		    bits := toInt(y);
		    if bits == 0
		    then toExpr(moveToRR(Ccode(RRmutable, "*(mpfr_ptr*)", x.v)))
		    else if bits == 32
		    then toExpr(Ccode(float, "*(float *)", x.v))
		    else if bits == 64
		    then toExpr(Ccode(double, "*(double *)", x.v))
		    else buildErrorPacket("expected 0, 32, or 64"))
		else WrongArgZZ(2))
	    else WrongArgPointer(1))
	else WrongNumArgs(2))
    else WrongNumArgs(2));
setupfun("ffiRealValue", ffiRealValue);

-------------------
-- pointer types --
-------------------

setupconst("ffiPointerType", toExpr(Ccode(voidPointer, "&ffi_type_pointer")));

ffiPointerAddress(e:Expr):Expr := (
    when e
    is x:pointerCell do (
	y := getMem(pointerSize);
	Ccode(void, "*(void **)", y, " = ", x.v);
	toExpr(y))
    is x:stringCell do (
	y := getMem(pointerSize);
	Ccode(void, "*(void **)", y, " = ", tocharstar(x.v));
	toExpr(y))
    is a:Sequence do (
	if length(a) == 2 then (
	    when a.0
	    is x:pointerCell do (
		when a.1
		is y:List do (
		    n := length(y.v);
		    bytes := Ccode(int, "((ffi_type *)", x.v, ")->size");
		    arr := getMem(n * bytes);
		    for i from 0 to n - 1 do (
			when y.v.i
			is z:pointerCell do Ccode(void,
			    "memcpy(", arr, " + ", i * bytes, ", ",
			    z.v, ", ", bytes, ")")
			else return buildErrorPacket(
			    "expected a list of pointers"));
		    ptr := getMem(pointerSize);
		    Ccode(void, "*(void **)", ptr, " = ", arr);
		    toExpr(ptr))
		else WrongArg(2, "a list"))
	    else WrongArgPointer(1))
	else WrongNumArgs(1, 2))
    else WrongArg("a pointer, string, or a pointer and a list"));
setupfun("ffiPointerAddress", ffiPointerAddress);

ffiPointerValue(e:Expr):Expr := (
    when e
    is x:pointerCell do toExpr(Ccode(voidPointer, "*(void **)", x.v))
    else WrongArgPointer());
setupfun("ffiPointerValue", ffiPointerValue);

ffiStringValue(e:Expr):Expr := (
    when e
    is x:pointerCell do toExpr(tostring(Ccode(charstar, "*(char **)", x.v)))
    else WrongArgPointer());
setupfun("ffiStringValue", ffiStringValue);

ptrfinalizer(x:voidPointer, a:Sequence):void := (
    if length(a) == 2 then (
	applyEE(a.0, a.1);
	nothing)
    else nothing);

registerFinalizerForPointer(e:Expr):Expr := (
    when e is s:Sequence do (
	if length(s) == 3 then (
	    when s.0
	    is x:pointerCell do (
		a := new Sequence len 2 at i do provide s.(i + 1);
		Ccode(void, "GC_REGISTER_FINALIZER(", x.v, ", ",
		    "(GC_finalization_proc)", ptrfinalizer, ", ", a, ", 0, 0)");
		nullE)
	    else WrongArgPointer(1))
	else WrongNumArgs(3))
    else WrongNumArgs(3));
setupfun("registerFinalizerForPointer", registerFinalizerForPointer);

------------------
-- struct types --
------------------

ffiStructType(e:Expr):Expr := (
    when e
    is a:List do (
	x := getMem(Ccode(int, "sizeof(ffi_type)"));
	Ccode(void, "((ffi_type *)", x, ")->size = 0");
	Ccode(void, "((ffi_type *)", x, ")->alignment = 0");
	Ccode(void, "((ffi_type *)", x, ")->type = FFI_TYPE_STRUCT");
	n := length(a.v);
	elmnts := new array(voidPointer) len n + 1 at i do provide (
	    if i < n then (
		when a.v.i
		is p:pointerCell do p.v
		else nullPointer())
	    else nullPointer());
	Ccode(void, "((ffi_type *)", x, ")->elements = (ffi_type **)",
	    elmnts, "->array");
	toExpr(x))
    else WrongArg("a list"));
setupfun("ffiStructType", ffiStructType);

ffiGetStructOffsets(e:Expr):Expr :=
    when e
    is x:pointerCell do (
	n := 0;
	while Ccode(voidPointer, "(((ffi_type *)", x.v, ")->elements)[", n,
	    "]") != nullPointer() do n = n + 1;
	offsets := Ccode(voidPointer, "getmem((", n , ") * sizeof(size_t))");
	r := Ccode(int, "ffi_get_struct_offsets(FFI_DEFAULT_ABI, ",
	    "(ffi_type *)", x.v, ", (size_t *)", offsets, ")");
	if r != ffiOk then return ffiError(r);
	Expr(list(new Sequence len n at i do provide
	    toExpr(Ccode(int, "((size_t *)", offsets, ")[", i, "]")))))
    else WrongArgPointer();
setupfun("ffiGetStructOffsets", ffiGetStructOffsets);

ffiStructAddress(e:Expr):Expr := (
    when e
    is a:Sequence do (
	if length(a) == 2 then (
	    when a.0
	    is x:pointerCell do (
		when a.1 is y:List do (
		    n := 0;
		    while Ccode(voidPointer, "(((ffi_type *)", x.v,
			")->elements)[", n, "]") != nullPointer() do n = n + 1;
		    offsets := Ccode(voidPointer, "getmem((", n ,
			") * sizeof(size_t))");
		    r := Ccode(int, "ffi_get_struct_offsets(FFI_DEFAULT_ABI, ",
			"(ffi_type *)", x.v, ", (size_t *)", offsets, ")");
		    if r != ffiOk then return ffiError(r);
		    result := getMem(Ccode(int, "((ffi_type *)", x.v,
			    ")->size"));
		    for i from 0 to n - 1 do (
			when y.v.i
			is elmnt:pointerCell do (
			    tocopy := Ccode(int, "(((ffi_type *)", x.v,
				")->elements)[", i, "]->size");
			    Ccode(void, "memcpy(", result, " + ((size_t *)",
				offsets, ")[", i, "],", elmnt.v, ", ",
				tocopy, ")"))
			else nothing);
		    toExpr(result))
		else WrongArg(2, "a list"))
	    else WrongArgPointer(1))
	else WrongNumArgs(2))
    else WrongNumArgs(2));
setupfun("ffiStructAddress", ffiStructAddress);

-----------------
-- union types --
-----------------

-- ffi_prep_cif trick from libffi manual
ffiUnionType(e:Expr):Expr := (
    when e
    -- expects a list of pointers to ffi_type's
    is a:List do (
	x := getMem(Ccode(int, "sizeof(ffi_type)"));
	Ccode(void, "((ffi_type *)", x, ")->size = 0");
	Ccode(void, "((ffi_type *)", x, ")->alignment = 0");
	Ccode(void, "((ffi_type *)", x, ")->type = FFI_TYPE_STRUCT");
	elmnts := new array(voidPointer) len 2 do provide nullPointer();
	Ccode(void, "((ffi_type *)", x, ")->elements = (ffi_type **)",
	    elmnts, "->array");
	cif := getMem(Ccode(int, "sizeof(ffi_cif)"));
	for i from 0 to length(a.v) - 1 do (
	    when a.v.i
	    is p:pointerCell do (
		if Ccode(int, "ffi_prep_cif((ffi_cif *)", cif,
		    ", FFI_DEFAULT_ABI, 0, ", p.v, ", NULL)") == ffiOk then (
		    if Ccode(int, "((ffi_type *)", p.v , ")->size"
			) > Ccode(int, "((ffi_type *)", x, ")->size"
			) then (Ccode(void, "((ffi_type *)", x,
			    ")->size = ((ffi_type *)", p.v, ")->size"));
		    if Ccode(int, "((ffi_type *)", p.v, ")->alignment"
			) > Ccode(int, "((ffi_type *)", x, ")->alignment"
			) then (Ccode(void, "((ffi_type *)", x,
			    ")->alignment = ((ffi_type *)", p.v,
			    ")->alignment"))))
	    else return WrongArgPointer(i + 1));
	toExpr(x))
    else WrongArg("a list"));
setupfun("ffiUnionType", ffiUnionType);

----------------------------
-- function pointer types --
----------------------------

ffiClosureFunction(cif:Pointer "ffi_cif *", ret:voidPointer,
    args:Pointer "void **", userData:voidPointer):void := (
    nargs := Ccode(int, cif, "->nargs");
    f := Expr(Ccode(FunctionClosure, userData));
    x := Expr(
	if nargs == 1 then Expr(pointerCell(Ccode(voidPointer, "*", args)))
	else Expr(new Sequence len nargs at i do provide pointerCell(
		Ccode(voidPointer, args, "[", i, "]"))));
    when applyEE(f, x)
    is ptr:pointerCell
    do Ccode(void, "memcpy(",
	endianAdjust(ret, Ccode(voidPointer, "((ffi_cif *)", cif, ")->rtype")),
	", ", ptr.v, ", ", cif, "->rtype->size)")
    is err:Error do printErrorMessage(err)
    else nothing);

ffiClosureFinalizer(ptr:voidPointer, closure:voidPointer):void := (
    Ccode(void, "ffi_closure_free(", closure, ")"));

ffiFunctionPointerAddress(e:Expr):Expr := (
    when e
    is a:Sequence do (
	when a.0
	is f:FunctionClosure do (
	    when a.1
	    is cif:pointerCell do (
		code := nullPointer();
		closure := Ccode(voidPointer,
		    "ffi_closure_alloc(sizeof(ffi_closure), &", code, ")");
		if closure == nullPointer() then return buildErrorPacket(
		    "ffi_closure_alloc() returned NULL");
		r := Ccode(int, "ffi_prep_closure_loc(", closure, ", ", cif.v,
		    ", ", ffiClosureFunction, ", ", f, ", ", code, ")");
		if r != ffiOk then return ffiError(r);
		ptr := getMem(pointerSize);
		Ccode(void, "*(void **)", ptr, " = ", closure);
		Ccode(void, "GC_REGISTER_FINALIZER(", ptr, ", ",
		    "(GC_finalization_proc)", ffiClosureFinalizer, ", ",
		    closure, ", 0, 0)");
		toExpr(ptr))
	    else WrongArgPointer(2))
	else WrongArg(1, "a function"))
    else WrongNumArgs(2));
setupfun("ffiFunctionPointerAddress", ffiFunctionPointerAddress);

getMemory0(e:Expr):Expr := (
    when e
    is a:Sequence
    do (
	when a.0
	is n:ZZcell do (
	    if !isInt(n) then WrongArgSmallInteger(1)
	    else when a.1
	    is atomic:Boolean do (
		if atomic.v then toExpr(getMemAtomic(toInt(n.v)))
		else toExpr(getMem(toInt(n.v))))
	    else WrongArgBoolean(2))
	else WrongArgZZ(1))
    else WrongNumArgs(2));
setupfun("getMemory0", getMemory0);
