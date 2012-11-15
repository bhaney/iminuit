#cython: embedsignature=True
__all__ = ['Minuit']
from libcpp.vector cimport vector
from libcpp.string cimport string
from cpython cimport exc
#from libcpp import bool
from util import *
from warnings import warn
from cython.operator cimport dereference as deref
from libc.math cimport sqrt
from pprint import pprint
from ConsoleFrontend import ConsoleFrontend
include "Lcg_Minuit.pxi"
include "Minuit2Struct.pxi"

#our wrapper
cdef extern from "PythonFCN.h":
    #int raise_py_err()#this is very important we need custom error handler
    FunctionMinimum* call_mnapplication_wrapper(\
        MnApplication app,unsigned int i, double tol) except +
    cdef cppclass PythonFCN(FCNBase):
        PythonFCN(\
            object fcn, double up_parm, vector[string] pname,bint thrownan)
        double call "operator()" (vector[double] x) except +#raise_py_err
        double up()
        int getNumCall()
        void set_up(double up)
        void resetNumCall()


#look up map with default
cdef maplookup(m,k,d):
    return m[k] if k in m else d


cdef class Minuit:
    #standard stuff

    cdef readonly object fcn #:fcn
    #cdef readonly object varname #:variable names
    """this should work"""
    cdef readonly object pos2var#:map variable position to varname
    """or this should work"""
    cdef readonly object var2pos#:map varname to position

    #Initial settings
    cdef object initialvalue #:hold initial values
    cdef object initialerror #:hold initial errors
    cdef object initiallimit #:hold initial limits
    cdef object initialfix #:hold initial fix state

    #C++ object state
    cdef PythonFCN* pyfcn #:FCN
    cdef MnApplication* minimizer #:migrad
    cdef FunctionMinimum* cfmin #:last migrad result
    #:last parameter state(from hesse/migrad)
    cdef MnUserParameterState* last_upst

    #PyMinuit compatible field
    cdef public double up #:UP parameter
    cdef public double tol #:tolerance migrad stops when edm>0.0001*tol*UP
    cdef public unsigned int strategy #:0 fast 1 default 2 slow but accurate
    #: 0: quiet 1: print stuff the end 2: 1+fit status during call
    #: yes I know the case is wrong but this is to keep it compatible with
    #: PyMinuit
    cdef public printMode
    #: raise runtime error if function evaluate to nan
    cdef readonly bint throw_nan

    #PyMinuit Compatible interface
    cdef readonly object parameters#:tuple of parameter name(correct order)
    cdef readonly object args#:tuple of values
    cdef readonly object values#:map varname -> value
    cdef readonly object errors#:map varname -> parabolic error
    cdef readonly object covariance#:map (v1,v2)->covariance
    cdef readonly double fval#:last value of fcn
    cdef readonly double ncalls#:number of fcn call of last migrad/minos/hesse
    cdef readonly double edm#Estimate distance to minimum
    #:minos error ni a funny map from
    #:(vname,direction)->error
    #:direction is 1.0 for positive error and -1.0 for negative error
    cdef readonly object merrors
    #:global correlation coefficient
    cdef readonly object gcc
    #and some extra
    #:map of
    #:varname -> value
    #:error_varname -> error
    #:limit_varname -> limit
    #:fix_varname -> True/False
    #:user can just use python keyword expansion to use all the argument like
    #:Minuit(fcn,**fitargs)
    cdef public object fitarg
    cdef readonly object narg#: number of arguments
    #: map vname-> struct with various minos error calcumation information
    cdef public object merrors_struct
    cdef public object frontend

    def __init__(self, fcn,
            throw_nan=False,  pedantic=True,
            frontend=None, forced_parameters=None, printMode=1, **kwds):
        """construct minuit object
        arguments of f are pased automatically by the following order
        1) using f.func_code.co_varnames,f.func_code.co_argcount
        (all python function has this)
        2) using f.__call__.func_code.co_varnames, f.__call__.co_argcount
        (with self docked off)
        3) using inspect.getargspec(for some rare builtin function)
        *forced_parameters*: ignore all the auto argument discovery
        mechanism and use this given list of parameter names

        user can set limit on paramater by passing
        limit_<varname>=(min,max) keyword argument
        user can set initial value onparameter by passing
        <varname>=value keyword argument
        user can fix parameter by doing
        fix_<varname>=True
        user can set initial step by passing
        error_<varname>=initialstep keyword argument

        if f_verbose is set to True FCN will be built for verbosity
        printing value and argument for every function call
        """

        args = better_arg_spec(fcn) if forced_parameters is None\
               else forced_parameters
        narg = len(args)
        self.fcn = fcn

        self.frontend = self.auto_frontend() if frontend is None else frontend

        #maintain 2 dictionary 1 is position to varname
        #and varname to position
        #self.varname = args
        self.pos2var = {i: k for i, k in enumerate(args)}
        self.var2pos = {k: i for i, k in enumerate(args)}

        self.args, self.values, self.errors = None, None, None

        self.initialvalue = {x:maplookup(kwds,x,0.) for x in args}
        self.initialerror = \
            {x:maplookup(kwds,'error_'+x,1.) for x in args}
        self.initiallimit = \
            {x:maplookup(kwds,'limit_'+x,None) for x in args}
        self.initialfix = \
            {x:maplookup(kwds,'fix_'+x,False) for x in args}

        self.pyfcn = NULL
        self.minimizer = NULL
        self.cfmin = NULL
        self.last_upst = NULL

        self.up = 1.0
        self.tol = 0.1
        self.strategy = 1
        self.printMode = printMode
        self.throw_nan = throw_nan

        self.parameters = args
        self.args = None
        self.values = None
        self.errors = None
        self.covariance = None
        self.fval = 0.
        self.ncalls = 0
        self.edm = 1.
        self.merrors = {}
        self.gcc = {}
        if pedantic: self.pedantic(kwds)

        self.fitarg = {}
        self.fitarg.update(self.initialvalue)
        self.fitarg.update(
            {'error_'+k:v for k,v in self.initialerror.items()})
        self.fitarg.update(
            {'limit_'+k:v for k,v in self.initiallimit.items()})
        self.fitarg.update(
            {'fix_'+k:v for k,v in self.initialfix.items()})

        self.narg = len(self.parameters)

        self.merrors_struct = {}


    def auto_frontend(self):
        """determine front end automatically.
        If this session is an IPYTHON session then use Html frontend,
        Console Frontend otherwise.
        """
        try:
            __IPYTHON__
            from HtmlFrontend import HtmlFrontend
            return HtmlFrontend()
        except NameError:
            return ConsoleFrontend()


    def migrad(self,int ncall=1000,resume=True, forced_parameters=None):
        """run migrad, the age-tested(over 40 years old, no kidding), super
        robust and stable minimization algorithm.
        You can read how it does the magic at
        `here <http://wwwasdoc.web.cern.ch/wwwasdoc/minuit/minmain.html>`_.

        Arguments:

            *ncall*: integer (approximate) maximum number of call before
            migrad stop trying. Default 1000

            *resume*: boolean indicating whether migrad should start from
            previous minimizer attempt(True) or should start from the
            beginning(False). Default False.

        Return:

            FunctionMinum Struct, list of parameter states -- DOCUMENT THIS
        """
        #construct new fcn and migrad if
        #it's a clean state or resume=False
        cdef MnUserParameterState* ups = NULL
        cdef MnStrategy* strat = NULL

        if self.printMode>0: self.frontend.print_banner('MIGRAD')

        if not resume or self.is_clean_state():
            self.construct_FCN()
            if self.minimizer is not NULL: del self.minimizer
            ups = self.initialParameterState()
            strat = new MnStrategy(self.strategy)
            self.minimizer = \
                    new MnMigrad(deref(self.pyfcn),deref(ups),deref(strat))
            del ups; ups=NULL
            del strat; strat=NULL

        if not resume: self.pyfcn.resetNumCall()

        del self.cfmin #remove the old one

        #this returns a real object need to copy
        self.cfmin = call_mnapplication_wrapper(
                deref(self.minimizer),ncall,self.tol)

        del self.last_upst

        self.last_upst = new MnUserParameterState(self.cfmin.userState())
        self.refreshInternalState()

        if self.printMode>0: self.print_fmin()

        return self.get_fmin(), self.get_param_states()


    def hesse(self):
        """run HESSE.
        HESSE estimate error by the second derivative at the minimim.

        return list of MinuitParameter struct
        """

        cdef MnHesse* hesse = NULL
        cdef MnUserParameterState upst
        if self.printMode>1: self.frontend.print_banner('HESSE')
        if self.cfmin is NULL:
            raise RuntimeError('Run migrad first')
        hesse = new MnHesse(self.strategy)
        upst = hesse.call(deref(self.pyfcn),self.cfmin.userState())

        del self.last_upst
        self.last_upst = new MnUserParameterState(upst)
        self.refreshInternalState()
        del hesse
        if self.printMode>1: self.print_param()
        return self.get_param_states()


    def minos(self, var = None, sigma = None, unsigned int maxcall=1000):
        """run minos for paramter *var* n *sigma* uncertainty.
        If *var* is None it runs minos for all parameters

        return dictionary of varname to minos struct if minos is requested
        for all parameters. If minos is requested only for one parameter,
        minos error struct is returned.
        """
        cdef unsigned int index = 0
        cdef MnMinos* minos = NULL
        cdef MinosError mnerror
        cdef char* name = NULL
        if self.printMode>0: self.frontend.print_banner('MINOS')
        if sigma is not None:
            raise RuntimeError(
                'sigma is deprecated use set_up(up*sigma*sigma) instead')
        if not self.cfmin.isValid():
            raise RuntimeError(('Function mimimum is not valid. Make sure'
                ' migrad converge first'))
        ret = None
        if var is not None:
            name = var
            index = self.cfmin.userState().index(var)
            if self.cfmin.userState().minuitParameters()[i].isFixed():
                return None
            minos = new MnMinos(deref(self.pyfcn), deref(self.cfmin),strategy)
            mnerror = minos.minos(index,maxcall)
            ret = minoserror2struct(mnerror)
            self.merrors_struct[var]=ret
            if self.printMode>0:
                self.frontend.print_merror(var,self.merrors_struct[var])
        else:
            for vname in self.parameters:
                index = self.cfmin.userState().index(vname)
                if self.cfmin.userState().minuitParameters()[index].isFixed():
                    continue
                minos = new MnMinos(deref(
                    self.pyfcn), deref(self.cfmin),self.strategy)
                mnerror = minos.minos(index,maxcall)
                self.merrors_struct[vname]=minoserror2struct(mnerror)
                if self.printMode>0:
                    self.frontend.print_merror(
                        vname,self.merrors_struct[vname])
        self.refreshInternalState()
        del minos

        return self.merrors_struct if ret is None else ret


    def matrix(self, correlation=False, skip_fixed=False):
        """return error/correlation matrix in tuple or tuple format."""
        if self.last_upst is NULL:
            raise RuntimeError("Run migrad/hesse first")
        cdef MnUserCovariance cov = self.last_upst.covariance()
        if correlation:
            ret = tuple(
                tuple(cov.get(iv1,iv2)/sqrt(cov.get(iv1,iv1)*cov.get(iv2,iv2))
                    for iv1,v1 in enumerate(self.parameters)\
                        if not skip_fixed or not self.is_fixed(v1))
                    for iv2,v2 in enumerate(self.parameters) \
                        if not skip_fixed or not self.is_fixed(v2)
                )
        else:
            ret = tuple(
                    tuple(cov.get(iv1,iv2)
                        for iv1,v1 in enumerate(self.parameters)\
                            if not skip_fixed or not self.is_fixed(v1))
                        for iv2,v2 in enumerate(self.parameters) \
                            if not skip_fixed or not self.is_fixed(v2)
                    )
        return ret


    def print_matrix(self):
        matrix = self.matrix(correlation=True, skip_fixed=True)
        vnames = self.list_of_vary_param()
        self.frontend.print_matrix(vnames, matrix)


    def np_matrix(self, correlation=False, skip_fixed=False):
        """return error/correlation matrix in numpy array format."""
        import numpy as np
        #TODO make a not so lazy one
        return np.array(matrix)


    # def error_matrix(self, correlation=False):
    #     ndim = self.mnstat().npari
    #     #void mnemat(Double_t* emat, Int_t ndim)
    #     tmp = array('d', [0.] * (ndim * ndim))
    #     self.tmin.mnemat(tmp, ndim)
    #     ret = np.array(tmp)
    #     ret = ret.reshape((ndim, ndim))
    #     if correlation:
    #         diag = np.diagonal(ret)
    #         sigma_col = np.sqrt(diag[:, np.newaxis])
    #         sigma_row = sigma_col.T
    #         ret = ret / sigma_col / sigma_row
    #     return ret


    def is_fixed(self,vname):
        """check if variable *vname* is (initialy) fixed"""
        if vname not in self.parameters:
            raise RuntimeError('Cannot find %s in list of variables.')
        cdef unsigned int index = self.var2pos[vname]
        if self.last_upst is NULL:
            return self.initialfix[vname]
        else:
            return self.last_upst.minuitParameters()[index].isFixed()


    def scan(self):
        """NOT IMPLEMENTED"""
        #anyone actually use this?
        raise NotImplementedError


    def contour(self):
        """NOT IMPLEMENTED"""
        #and this?
        raise NotImplementedError


    #dealing with frontend conversion
    def print_param(self):
        """print current parameter state"""
        if self.last_upst is NULL:
            self.print_initial_param()
        cdef vector[MinuitParameter] vmps = self.last_upst.minuitParameters()
        cdef int i
        tmp = []
        for i in range(vmps.size()):
            tmp.append(minuitparam2struct(vmps[i]))
        self.frontend.print_param(tmp, self.merrors_struct)


    def print_initial_param(self):
        """Print initial parameters"""
        raise NotImplementedError


    def print_fmin(self):
        """print current function minimum state"""
        #cdef MnUserParameterState ust = MnUserParameterState(
        #                               self.cfmin.userState())
        sfmin = cfmin2struct(self.cfmin)
        ncalls = 0 if self.pyfcn is NULL else self.pyfcn.getNumCall()

        self.frontend.print_hline()
        self.frontend.print_fmin(sfmin,self.tol,ncalls)
        self.print_param()
        self.frontend.print_hline()



    def print_all_minos(self):
        """print all minos errors(and its states)"""
        for vname in varnames:
            if vname in self.merrors_struct:
                self.frontend.print_mnerror(vname,self.merrors_struct[vname])


    def set_up(self, double up):
        """set UP parameter 1 for chi^2 and 0.5 for log likelihood"""
        self.up = up
        if self.pyfcn is not NULL:
            self.pyfcn.set_up(up)


    def set_strategy(self,stra):
        """set strategy 0=fast , 1=default, 2=slow but accurate"""
        self.strategy=stra


    def set_print_mode(self, lvl):
        """set printlevel 0 quiet, 1 normal, 2 paranoid, 3 really paranoid """
        self.printMode = lvl


    def get_fmin(self):
        """return current FunctionMinimum Struct"""
        return cfmin2struct(self.cfmin) if self.cfmin is not NULL else None


    #expose internal state using various struct
    def get_param_states(self):
        """Return a list of current MinuitParameter Struct
        for all parameters
        """
        if self.last_upst is NULL:
            return self.get_initial_param_state()
        cdef vector[MinuitParameter] vmps = self.last_upst.minuitParameters()
        cdef int i
        ret = []
        for i in range(vmps.size()):
            ret.append(minuitparam2struct(vmps[i]))
        return ret


    def get_merrors(self):
        """Returns a dictionary of varname-> MinosError Struct"""
        return self.merrors_struct


    def get_initial_param_state(self):
        """get initiail setting inform of MinuitParameter Struct"""
        raise NotImplementedError


    def get_num_call_fcn(self):
        """return number of total call to fcn(not just the last operation)"""
        return 0 if self.pyfcn is NULL else self.pyfcn.getNumCall()


    def migrad_ok(self):
        """check if minimum is valid"""
        return self.cfmin is not NULL and self.fmin.isValid()


    def matrix_acurate(self):
        """check if covariance is accurate"""
        return self.last_upst is not NULL and self.last_upst.hasCovariance()

    #html* function has to go away
    def html_results(self):
        """show result in html form"""
        return MinuitHTMLResult(self)


    def html_error_matrix(self):
        """show error matrix in html form"""
        return MinuitCorrelationMatrixHTML(self)


    def list_of_fixed_param(self):
        """return list of (initially) fixed parameters"""
        return [v for v in self.parameters if self.initialfix[v]]


    def list_of_vary_param(self):
        """return list of (initially) float vary parameters"""
        return [v for v in self.parameters if not self.initialfix[v]]

    #Various utility functions
    cdef construct_FCN(self):
        """(re)construct FCN"""
        del self.pyfcn
        self.pyfcn = new PythonFCN(
                self.fcn,
                self.up,
                self.parameters,
                self.throw_nan)


    def is_clean_state(self):
        """check if minuit is at clean state ie. no migrad call"""
        return self.pyfcn is NULL and \
            self.minimizer is NULL and self.cfmin is NULL


    cdef void clear_cobj(self):
        #clear C++ internal state
        del self.pyfcn;self.pyfcn = NULL
        del self.minimizer;self.minimizer = NULL
        del self.cfmin;self.cfmin = NULL
        del self.last_upst;self.last_upst = NULL


    def __dealloc__(self):
        self.clear_cobj()


    def pedantic(self, kwds):
        for vn in self.parameters:
            if vn not in kwds:
                warn(('Parameter %s does not have initial value. '
                    'Assume 0.') % (vn))
            if 'error_'+vn not in kwds and 'fix_'+param_name(vn) not in kwds:
                warn(('Parameter %s is floating but does not '
                    'have initial step size. Assume 1.') % (vn))
        for vlim in extract_limit(kwds):
            if param_name(vlim) not in self.parameters:
                warn(('%s is given. But there is no parameter %s. '
                    'Ignore.') % (vlim, param_name(vlim)))
        for vfix in extract_fix(kwds):
            if param_name(vfix) not in self.parameters:
                warn(('%s is given. But there is no parameter %s. \
                    Ignore.') % (vfix, param_name(vfix)))
        for verr in extract_error(kwds):
            if param_name(verr) not in self.parameters:
                warn(('%s float. But there is no parameter %s. \
                    Ignore.') % (verr, param_name(verr)))


    cdef refreshInternalState(self):
        """refresh internal state attributes.
        These attributes should be in a function instead
        but kept here for PyMinuit compatiblity
        """
        cdef vector[MinuitParameter] mpv
        cdef MnUserCovariance cov
        if self.last_upst is not NULL:
            mpv = self.last_upst.minuitParameters()
            self.values = {}
            self.errors = {}
            self.args = []
            for i in range(mpv.size()):
                self.args.append(mpv[i].value())
                self.values[mpv[i].name()] = mpv[i].value()
                self.errors[mpv[i].name()] = mpv[i].value()
            self.args = tuple(self.args)
            self.fitarg.update(self.values)
            cov = self.last_upst.covariance()
            self.covariance =\
                {(self.parameters[i],self.parameters[j]):cov.get(i,j)\
                    for i in range(self.narg) for j in range(self.narg)}
            self.fval = self.last_upst.fval()
            self.ncalls = self.last_upst.nfcn()
            self.edm = self.last_upst.edm()
            self.gcc = {v:self.last_upst.globalCC().globalCC()[i]\
                        for i,v in enumerate(self.parameters)}
        self.merrors = {(k,1.0):v.upper
                       for k,v in self.merrors_struct.items()}
        self.merrors.update({(k,-1.0):v.lower
                       for k,v in self.merrors_struct.items()})


    cdef MnUserParameterState* initialParameterState(self):
        """construct parameter state from initial array.
        caller is responsible for cleaning up the pointer
        """
        cdef MnUserParameterState* ret = new MnUserParameterState()
        cdef double lb
        cdef double ub
        for v in self.parameters:
            ret.add(v,self.initialvalue[v],self.initialerror[v])
        for v in self.parameters:
            if self.initiallimit[v] is not None:
                lb,ub = self.initiallimit[v]
                ret.setLimits(v,lb,ub)
        for v in self.parameters:
            if self.initialfix[v]:
                ret.fix(v)
        return ret
