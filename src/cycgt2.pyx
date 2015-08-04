from libcpp.vector cimport vector
from cpython.ref cimport PyObject
cimport numpy as cnp
cimport cpython

import numpy as np
import ctypes
import os.path as osp

import cgt
from cgt import exceptions, core, execution, impls

cnp.import_array()

################################################################
### CGT common datatypes 
################################################################
 


cdef extern from "cgt_common.h":

    cppclass IRC[T]:
        pass

    cppclass cgtObject:
        pass

    ctypedef void (*cgtByRefFun)(void*, cgtObject**, cgtObject*);
    ctypedef cgtObject* (*cgtByValFun)(void*, cgtObject**);

    enum cgtDevtype:
        cgtCPU
        cgtGPU

    cppclass cgtArray(cgtObject):
        cgtArray(int, size_t*, cgtDtype, cgtDevtype)
        int ndim
        cgtDtype dtype
        cgtDevtype devtype
        size_t* shape
        void* data
        size_t stride
        bint ownsdata    

    cppclass cgtTuple(cgtObject):
        cgtTuple(size_t)
        void setitem(int, cgtObject*)
        cgtObject* getitem(int)
        size_t size();
        size_t len
        cgtObject** members        


    cdef enum cgtDtype:
        cgt_i1
        cgt_i2
        cgt_i4
        cgt_i8
        cgt_f2
        cgt_f4
        cgt_f8
        cgt_f16
        cgt_c8
        cgt_c16
        cgt_c32
        cgt_O

    size_t cgt_size(const cgtArray* a)
    int cgt_itemsize(cgtDtype dtype)
    size_t cgt_nbytes(const cgtArray* a)

    bint cgt_is_array(cgtObject*)
    bint cgt_is_tuple(cgtObject*)

    void* cgt_alloc(cgtDevtype devtype, size_t)    
    void cgt_free(cgtDevtype devtype, void* ptr)
    void cgt_memcpy(cgtDevtype dest_type, cgtDevtype src_type, void* dest_ptr, void* src_ptr, size_t nbytes)


# Conversion funcs
# ----------------------------------------------------------------

ctypedef cnp.Py_intptr_t npy_intp_t


cdef object cgt2py_object(cgtObject* o):
    if cgt_is_array(o): return cgt2py_array(<cgtArray*>o)
    elif cgt_is_tuple(o): return cgt2py_tuple(<cgtTuple*>o)
    else: raise RuntimeError("cgt object seems to be invalid")

cdef object cgt2py_array(cgtArray* a):
    cdef cnp.ndarray nparr = cnp.PyArray_SimpleNew(a.ndim, <npy_intp_t*>a.shape, a.dtype) # XXX DANGEROUS CAST
    cgt_memcpy(cgtCPU, a.devtype, cnp.PyArray_DATA(nparr), a.data, cnp.PyArray_NBYTES(nparr))
    return nparr

cdef object cgt2py_tuple(cgtTuple* t):
    cdef int i
    return tuple(cgt2py_object(t.getitem(i)) for i in xrange(t.len))
    # why doesn't the following work:
    # out = cpython.PyTuple_New(t.len)
    # for i in xrange(t.len):
    #     cpython.PyTuple_SetItem(out, i, cgt2py_object(t.getitem(i)))
    # return out

cdef cnp.ndarray _to_valid_array(object arr):
    cdef cnp.ndarray out = np.asarray(arr, order='C')
    if not out.flags.c_contiguous: 
        out = out.copy()
    return out

cdef cgtObject* py2cgt_object(object o) except *:
    if isinstance(o, tuple):
        return py2cgt_tuple(o)
    else:
        o = _to_valid_array(o)
        return py2cgt_Array(o)

cdef cgtArray* py2cgt_Array(cnp.ndarray arr):
    cdef cgtArray* out = new cgtArray(arr.ndim, <size_t*>arr.shape, dtype_fromstr(arr.dtype), cgtCPU)
    cgt_memcpy(out.devtype, cgtCPU, out.data, cnp.PyArray_DATA(arr), cgt_nbytes(out))
    return out

cdef cgtTuple* py2cgt_tuple(object o):
    cdef cgtTuple* out = new cgtTuple(len(o))
    cdef int i
    for i in xrange(len(o)):
        out.setitem(i, py2cgt_object(o[i]))
    return out


cdef cgtDtype dtype_fromstr(s):
    if s=='i1':
        return cgt_i1
    elif s=='i2':
        return cgt_i2
    elif s=='i4':
        return cgt_i4
    elif s=='i8':
        return cgt_i8
    elif s=='f2':
        return cgt_f2
    elif s=='f4':
        return cgt_f4
    elif s=='f8':
        return cgt_f8
    elif s=='f16':
        return cgt_f16
    elif s=='c8':
        return cgt_c8
    elif s=='c16':
        return cgt_c16
    elif s=='c32':
        return cgt_c32
    elif s == 'O':
        return cgt_O
    else:
        raise ValueError("unrecognized dtype %s"%s)

cdef object dtype_tostr(cgtDtype d):
    if d == cgt_i1:
        return 'i1'
    elif d == cgt_i2:
        return 'i2'
    elif d == cgt_i4:
        return 'i4'
    elif d == cgt_i8:
        return 'i8'
    elif d == cgt_f4:
        return 'f4'
    elif d == cgt_f8:
        return 'f8'
    elif d == cgt_f16:
        return 'f16'
    elif d == cgt_c8:
        return 'c8'
    elif d == cgt_c16:
        return 'c16'
    elif d == cgt_c32:
        return 'c32'
    elif d == cgt_O:
        return 'obj'
    else:
        raise ValueError("invalid cgtDtype")

cdef object devtype_tostr(cgtDevtype d):
    if d == cgtCPU:
        return "cpu"
    elif d == cgtGPU:
        return "gpu"
    else:
        raise RuntimeError

cdef cgtDevtype devtype_fromstr(object s):
    if s == "cpu":
        return cgtCPU
    elif s == "gpu":
        return cgtGPU
    else:
        raise ValueError("unrecognized devtype %s"%s)


################################################################
### Dynamic loading 
################################################################
 

cdef extern from "dlfcn.h":
    void *dlopen(const char *filename, int flag)
    char *dlerror()
    void *dlsym(void *handle, const char *symbol)
    int dlclose(void *handle) 
    int RTLD_GLOBAL
    int RTLD_LAZY
    int RTLD_NOW

LIB_DIRS = None
LIB_HANDLES = {}

def initialize_lib_dirs():
    global LIB_DIRS
    if LIB_DIRS is None:
        LIB_DIRS = [".cgt/build/lib"]

cdef void* get_or_load_lib(libname) except *:
    cdef void* handle
    initialize_lib_dirs()
    if libname in LIB_HANDLES:
        return <void*><size_t>LIB_HANDLES[libname]
    else:
        for ld in LIB_DIRS:
            libpath = osp.join(ld,libname)
            if osp.exists(libpath):
                handle = dlopen(libpath, RTLD_NOW | RTLD_GLOBAL)
            else:
                raise IOError("tried to load non-existent library %s"%libpath)
        if handle == NULL:
            raise ValueError("couldn't load library named %s: %s"%(libname, <bytes>dlerror()))
        else:
            LIB_HANDLES[libname] = <object><size_t>handle
        return handle


################################################################
### Execution graph 
################################################################
 
cdef extern from "execution.h" namespace "cgt":
    cppclass ByRefFunCl:
        ByRefFunCl(cgtByRefFun, void*)
        ByRefFunCl()
    cppclass ByValFunCl:
        ByValFunCl(cgtByValFun, void*)
        ByValFunCl()
    cppclass MemLocation:
        MemLocation(size_t)
        MemLocation()
    cppclass Instruction:
        pass
    cppclass ExecutionGraph:
        ExecutionGraph(vector[Instruction*], int, int)        
        int n_args()
    cppclass LoadArgument(Instruction):
        LoadArgument(int, MemLocation)
    cppclass Alloc(Instruction):
        Alloc(cgtDtype, vector[MemLocation], MemLocation)
    cppclass BuildTup(Instruction):
        BuildTup(vector[MemLocation], MemLocation)
    cppclass ReturnByRef(Instruction):
        ReturnByRef(vector[MemLocation], MemLocation, ByRefFunCl)
    cppclass ReturnByVal(Instruction):
        ReturnByVal(vector[MemLocation], MemLocation, ByValFunCl)

    cppclass Interpreter:
        cgtTuple* run(cgtTuple*)

    Interpreter* create_interpreter(ExecutionGraph*, vector[MemLocation])

# Conversion funcs
# ----------------------------------------------------------------

cdef vector[size_t] _tovectorlong(object xs):
    cdef vector[size_t] out = vector[size_t]()
    for x in xs: out.push_back(<size_t>x)
    return out

cdef object _cgtarray2py(cgtArray* a):
    raise NotImplementedError

cdef object _cgttuple2py(cgtTuple* t):
    raise NotImplementedError

cdef object _cgtobj2py(cgtObject* o):
    if cgt_is_array(o):
        return _cgtarray2py(<cgtArray*>o)
    else:
        return _cgttuple2py(<cgtTuple*>o)

cdef void* _ctypesstructptr(object o) except *:
    if o is None: return NULL
    else: return <void*><size_t>ctypes.cast(ctypes.pointer(o), ctypes.c_voidp).value    

cdef void _pyfunc_inplace(void* cldata, cgtObject** reads, cgtObject* write):
    (pyfun, nin, nout) = <object>cldata
    pyread = [cgt2py_object(reads[i]) for i in xrange(nin)]
    pywrite = cgt2py_object(write)
    try:
        pyfun(pyread, pywrite)
    except Exception as e:
        print e,pyfun
        raise e
    cdef cgtTuple* tup
    cdef cgtArray* a
    if cgt_is_array(write):
        npout = <cnp.ndarray>pywrite
        cgt_memcpy(cgtCPU, cgtCPU, (<cgtArray*>write).data, npout.data, cgt_nbytes(<cgtArray*>write))
    else:
        tup = <cgtTuple*> write
        for i in xrange(tup.size()):
            npout = <cnp.ndarray>pywrite[i]
            a = <cgtArray*>tup.getitem(i)
            assert cgt_is_array(a)
            cgt_memcpy(cgtCPU, cgtCPU, a.data, npout.data, cgt_nbytes(a))


cdef cgtObject* _pyfunc_valret(void* cldata, cgtObject** args):
    (pyfun, nin, nout) = <object>cldata
    pyread = [cgt2py_object(args[i]) for i in xrange(nin)]
    pyout = pyfun(pyread)
    return py2cgt_object(pyout)


shit2 = [] # XXX this is a memory leak, will fix later

cdef void* _getfun(libname, funcname) except *:
    cdef void* lib_handle = get_or_load_lib(libname)
    cdef void* out = dlsym(lib_handle, funcname)
    if out == NULL:
        raise RuntimeError("couldn't load function %s from %s. maybe you forgot extern C"%(libname, funcname))
    return out


cdef ByRefFunCl _node2inplaceclosure(node) except *:
    try:
        libname, funcname, cldata = impls.get_impl(node, "cpu") # TODO
        cfun = _getfun(libname, funcname)
        shit2.append(cldata)  # XXX
        return ByRefFunCl(<cgtByRefFun>cfun, _ctypesstructptr(cldata))
    except core.MethodNotDefined:
        pyfun = node.op.py_apply_inplace        
        cldata = (pyfun, len(node.parents), 1)
        shit2.append(cldata)
        return ByRefFunCl(&_pyfunc_inplace, <PyObject*>cldata)

cdef ByValFunCl _node2valretclosure(node) except *:
    try:
        libname, funcname, cldata = impls.get_impl(node, "cpu") # TODO
        cfun = _getfun(libname, funcname)
        shit2.append(cldata)  # XXX
        return ByValFunCl(<cgtByValFun>cfun, _ctypesstructptr(cldata))
    except core.MethodNotDefined:
        pyfun = node.op.py_apply_valret        
        cldata = (pyfun, len(node.parents), 1)
        shit2.append(cldata)
        return ByValFunCl(&_pyfunc_valret, <PyObject*>cldata)

cdef MemLocation _tocppmem(object pymem):
    return MemLocation(<size_t>pymem.index)

cdef vector[MemLocation] _tocppmemvec(object pymemlist) except *:
    cdef vector[MemLocation] out = vector[MemLocation]()
    for pymem in pymemlist:
        out.push_back(_tocppmem(pymem))
    return out

cdef Instruction* _tocppinstr(object pyinstr) except *:
    t = type(pyinstr)
    cdef Instruction* out
    if t == execution.LoadArgument:
        out = new LoadArgument(pyinstr.ind, _tocppmem(pyinstr.write_loc))
    elif t == execution.Alloc:
        out = new Alloc(dtype_fromstr(pyinstr.dtype), _tocppmemvec(pyinstr.read_locs), _tocppmem(pyinstr.write_loc))
    elif t == execution.BuildTup:
        out = new BuildTup(_tocppmemvec(pyinstr.read_locs), _tocppmem(pyinstr.write_loc))
    elif t == execution.ReturnByRef:
        out = new ReturnByRef(_tocppmemvec(pyinstr.read_locs), _tocppmem(pyinstr.write_loc), _node2inplaceclosure(pyinstr.node))
    elif t == execution.ReturnByVal:
        out = new ReturnByVal(_tocppmemvec(pyinstr.read_locs), _tocppmem(pyinstr.write_loc),_node2valretclosure(pyinstr.node))
    else:
        raise RuntimeError("expected instance of type Instruction. got type %s"%t)
    return out

################################################################
### Wrapper classes
################################################################

cdef ExecutionGraph* make_cpp_execution_graph(pyeg) except *:
    "make an execution graph object"
    cdef vector[Instruction*] instrs
    for instr in pyeg.instrs:
        instrs.push_back(_tocppinstr(instr))
    return new ExecutionGraph(instrs,pyeg.n_args, pyeg.n_locs)

cdef class CppInterpreterWrapper:
    """
    Convert python inputs to C++
    Run interpreter on execution graph
    Then grab the outputs
    """
    cdef ExecutionGraph* eg # owned
    cdef Interpreter* interp # owned
    def __init__(self, pyeg, input_types, output_locs):
        self.eg = make_cpp_execution_graph(pyeg)
        cdef vector[MemLocation] cpp_output_locs = _tocppmemvec(output_locs)
        self.interp = create_interpreter(self.eg, cpp_output_locs)
    def __dealloc__(self):
        if self.interp != NULL: del self.interp
        if self.eg != NULL: del self.eg
    def __call__(self, *pyargs):
        assert len(pyargs) == self.eg.n_args()
        # TODO: much better type checking on inputs
        cdef cgtTuple* cargs = new cgtTuple(len(pyargs))
        for (i,pyarg) in enumerate(pyargs):
            cargs.setitem(i, py2cgt_object(pyarg))
        cdef cgtTuple* ret = self.interp.run(cargs)
        del cargs
        return list(cgt2py_object(ret))

