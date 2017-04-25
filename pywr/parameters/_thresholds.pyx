from ._parameters import load_parameter
cimport numpy as np
import numpy as np

cdef enum Predicates:
    LT = 0
    GT = 1
    EQ = 2
    LE = 3
    GE = 4
_predicate_lookup = {
    "LT": Predicates.LT, "<": Predicates.LT,
    "GT": Predicates.GT, ">": Predicates.GT,
    "EQ": Predicates.EQ, "=": Predicates.EQ,
    "LE": Predicates.LE, "<=": Predicates.LE,
    "GE": Predicates.GE, ">=": Predicates.GE,
}

cdef class AbstractThresholdParameter(IndexParameter):
    """ Base class for parameters returning one of two values depending on other state.

    Parameters
    ----------
    threshold : double
        Threshold to compare the value of the recorder to
    values : iterable of doubles
        If the predicate evaluates False the zeroth value is returned,
        otherwise the first value is returned.
    predicate : string
        One of {"LT", "GT", "EQ", "LE", "GE"}.

    Methods
    -------
    value(timestep, scenario_index)
        Returns a value from the `values` attribute, using the index.
    index(timestep, scenario_index)
        Returns 1 if the predicate evaluates True, else 0.

    Notes
    -----
    On the first day of the model run the recorder will not have a value for
    the previous day. In this case the predicate evaluates to True.

    """
    def __init__(self, model, threshold, *args,  values=None, predicate=None, **kwargs):
        super(AbstractThresholdParameter, self).__init__(model, *args, **kwargs)
        self.threshold = threshold
        if values is None:
            self.values = None
        else:
            self.values = np.array(values, np.float64)
        if predicate is None:
            predicate = Predicates.LT
        elif isinstance(predicate, basestring):
            predicate = _predicate_lookup[predicate.upper()]
        self.predicate = predicate

    cpdef double _value_to_compare(self, Timestep timestep, ScenarioIndex scenario_index) except? -1:
        raise NotImplementedError()

    cpdef double value(self, Timestep timestep, ScenarioIndex scenario_index) except? -1:
        """Returns a value from the values attribute, using the index"""
        cdef int ind = self.get_index(scenario_index)
        cdef double v
        if self.values is not None:
            v = self.values[ind]
        else:
            return np.nan
        return v

    cpdef int index(self, Timestep timestep, ScenarioIndex scenario_index) except? -1:
        """Returns 1 if the predicate evalutes True, else 0"""
        cdef double x
        x = self._value_to_compare(timestep, scenario_index)

        if self.predicate == Predicates.LT:
            ind = x < self.threshold
        elif self.predicate == Predicates.GT:
            ind = x > self.threshold
        elif self.predicate == Predicates.LE:
            ind = x <= self.threshold
        elif self.predicate == Predicates.GE:
            ind = x >= self.threshold
        else:
            ind = x == self.threshold
        return ind


cdef class StorageThresholdParameter(AbstractThresholdParameter):
    """ Returns one of two values depending on current volume in a Storage node

    Parameters
    ----------
    recorder : `pywr.core.AbstractStorage`

    """
    def __init__(self, model, AbstractStorage storage, *args, **kwargs):
        super(StorageThresholdParameter, self).__init__(model, *args, **kwargs)
        self.storage = storage

    cpdef double _value_to_compare(self, Timestep timestep, ScenarioIndex scenario_index) except? -1:
        return self.storage._volume[scenario_index.global_id]

    @classmethod
    def load(cls, model, data):
        node = model._get_node_from_ref(model, data.pop("storage_node"))
        threshold = data.pop("threshold")
        values = data.pop("values", None)
        predicate = data.pop("predicate", None)
        return cls(model, node, threshold, values=values, predicate=predicate, **data)
StorageThresholdParameter.register()


cdef class NodeThresholdParameter(AbstractThresholdParameter):
    """ Returns one of two values depending on current flow in a node

    Parameters
    ----------
    recorder : `pywr.core.AbstractNode`

    """
    def __init__(self, model, AbstractNode node, *args, **kwargs):
        super(NodeThresholdParameter, self).__init__(model, *args, **kwargs)
        self.node = node

    cpdef double _value_to_compare(self, Timestep timestep, ScenarioIndex scenario_index) except? -1:
        return self.node._flow[scenario_index.global_id]

    @classmethod
    def load(cls, model, data):
        node = model._get_node_from_ref(model, data.pop("node"))
        threshold = data.pop("threshold")
        values = data.pop("values", None)
        predicate = data.pop("predicate", None)
        return cls(model, node, threshold, values=values, predicate=predicate, **data)
NodeThresholdParameter.register()


cdef class ParameterThresholdParameter(AbstractThresholdParameter):
    """ Returns one of two values depending on the value of a Parameter

    Parameters
    ----------
    recorder : `pywr.core.AbstractNode`

    """
    def __init__(self, model, Parameter param, *args, **kwargs):
        super(ParameterThresholdParameter, self).__init__(model, *args, **kwargs)
        self.param = param
        self.children.add(param)

    cpdef double _value_to_compare(self, Timestep timestep, ScenarioIndex scenario_index) except? -1:
        return self.param.get_value(scenario_index)

    @classmethod
    def load(cls, model, data):
        param = load_parameter(model, data.pop('parameter'))
        threshold = data.pop("threshold")
        values = data.pop("values", None)
        predicate = data.pop("predicate", None)
        return cls(model, param, threshold, values=values, predicate=predicate, **data)
ParameterThresholdParameter.register()


cdef class RecorderThresholdParameter(AbstractThresholdParameter):
    """Returns one of two values depending on a Recorder value and a threshold

    Parameters
    ----------
    recorder : `pywr.recorder.Recorder`

    """

    def __init__(self,  model, Recorder recorder, *args, initial_value=1, **kwargs):
        super(RecorderThresholdParameter, self).__init__(model, *args, **kwargs)
        self.recorder = recorder
        self.recorder.parents.add(self)
        self.initial_value = initial_value

    cpdef double _value_to_compare(self, Timestep timestep, ScenarioIndex scenario_index) except? -1:
        # TODO Make this a more general API on Recorder
        return self.recorder.data[timestep._index - 1, scenario_index.global_id]

    cpdef int index(self, Timestep timestep, ScenarioIndex scenario_index) except? -1:
        """Returns 1 if the predicate evalutes True, else 0"""
        cdef int index = timestep.index
        cdef int ind
        if index == 0:
            # on the first day the recorder doesn't have a value so we have no
            # threshold to compare to
            ind = self.initial_value
        else:
            ind = super(RecorderThresholdParameter, self).index(timestep, scenario_index)
        return ind

    @classmethod
    def load(cls, model, data):
        from pywr.recorders._recorders import load_recorder  # delayed to prevent circular reference
        recorder = load_recorder(model, data.pop("recorder"))
        threshold = data.pop("threshold")
        values = data.pop("values", None)
        predicate = data.pop("predicate", None)
        return cls(model, recorder, threshold, values=values, predicate=predicate, **data)
RecorderThresholdParameter.register()