# simple scheduler metadata store

const SHAREMODE_KEY = "S"
const TIMEOUT_KEY = ""

"""
Metadata store using broker in-memory datastructures
"""
mutable struct SimpleSchedMeta <: SchedMeta
    path::String
    brokerid::Int
    proclocal::Dict{String,Any}
    donetasks::Set{TaskIdType}
    sharemode::ShareMode
    results_channel::Union{Void,RemoteChannel{Channel{Tuple{String,String}}}}
    gen::Float64
    add_annotation::Function
    del_annotation::Function

    function SimpleSchedMeta(path::String, sharethreshold::Int)
        new(path, myid(),
            Dict{String,Any}(),
            Set{TaskIdType}(),
            ShareMode(sharethreshold),
            nothing, time(),
            identity, identity)
    end
end

function Base.show(io::IO, M::SimpleSchedMeta)
    print(io, "SimpleSchedMeta(", M.path, ")")
end

function init(M::SimpleSchedMeta, brokerid::String; add_annotation=identity, del_annotation=identity)
    M.brokerid = parse(Int, brokerid)
    M.add_annotation = add_annotation
    M.del_annotation = del_annotation
    M.results_channel = brokercall(()->register(RESULTS), M)
    donetasks = brokercall(broker_get_donetasks, M)::Set{TaskIdType}
    union!(M.donetasks, donetasks)
    nothing
end

function process_trigger(M::SimpleSchedMeta, k::String, v::String)
    if k == TIMEOUT_KEY
        # ignore
    elseif k == SHAREMODE_KEY
        nshared,ncreated,ndeleted = meta_deser(v)
        M.sharemode.nshared = nshared
        M.sharemode.ncreated = ncreated
        M.sharemode.ndeleted = ndeleted
    else
        val, refcount = meta_deser(v)
        M.proclocal[k] = val
        id = parse(TaskIdType, basename(k))
        push!(M.donetasks, id)
    end
    nothing
end

function process_triggers(M::SimpleSchedMeta)
    while isready(M.results_channel)
        (k,v) = take!(M.results_channel)
        process_trigger(M, k, v)
    end
end

function wait_trigger(M::SimpleSchedMeta; timeoutsec::Int=5)
    trigger = M.results_channel
    if !isready(trigger)
        @schedule begin
            sleep(timeoutsec)
            !isready(trigger) && put!(trigger, (TIMEOUT_KEY,""))
        end
    end

    # process results and sharemode notifications
    (k,v) = take!(M.results_channel)
    process_trigger(M, k, v)
    process_triggers(M)

    nothing
end

function delete!(M::SimpleSchedMeta)
    reset(M)
    if myid() === M.brokerid
        empty!(META)
        TASKS[] = Channel{TaskIdType}(1024)
        deregister(RESULTS)
    end
    nothing
end

function reset(M::SimpleSchedMeta)
    reset(M.sharemode)
    empty!(M.proclocal)
    empty!(M.donetasks)
    M.results_channel = nothing
    M.add_annotation = identity
    M.del_annotation = identity
    
    nothing
end

function cleanup(M::SimpleSchedMeta)
end

function share_task(M::SimpleSchedMeta, brokerid::String, id::TaskIdType)
    brokercall(()->broker_share_task(id, M.add_annotation(id), brokerid), M)
    nothing
end

function steal_task(M::SimpleSchedMeta, brokerid::String)
    taskid = brokercall(broker_steal_task, M)::TaskIdType
    ((taskid === NoTask) ? taskid : M.del_annotation(taskid))::TaskIdType
end

function set_result(M::SimpleSchedMeta, id::TaskIdType, val; refcount::UInt64=UInt64(1), processlocal::Bool=true)
    process_triggers(M)
    k = resultpath(M, id)
    M.proclocal[k] = val
    if !processlocal
        brokercall(()->broker_set_result(k, meta_ser((val,refcount))), M)
    end
    push!(M.donetasks, id)
    nothing
end

function get_result(M::SimpleSchedMeta, id::TaskIdType)
    process_triggers(M)
    k = resultpath(M, id)
    if k in keys(M.proclocal)
        M.proclocal[k]
    else
        v = brokercall(()->broker_get_result(k), M)::String
        val, refcount = meta_deser(v)
        M.proclocal[k] = val
        val
    end
end

function has_result(M::SimpleSchedMeta, id::TaskIdType)
    #process_triggers(M)
    id in M.donetasks
end

function decr_result_ref(M::SimpleSchedMeta, id::TaskIdType)
    2
end

function export_local_result(M::SimpleSchedMeta, id::TaskIdType, executable, refcount::UInt64)
    k = resultpath(M, id)
    (k in keys(M.proclocal)) || return

    exists = brokercall(()->broker_has_result(k), M)::Bool
    exists && return

    val = repurpose_result_to_export(executable, M.proclocal[k])
    brokercall(()->broker_set_result(k, meta_ser((val,refcount))), M)
    nothing
end

# --------------------------------------------------
# methods invoked at the broker
# --------------------------------------------------
function withtaskmutex(f)
    lock(taskmutex[])
    try
        return f()
    finally
        unlock(taskmutex[])
    end
end

function broker_has_result(k)
    k in keys(META)
end

function broker_share_task(id::TaskIdType, annotated::TaskIdType, brokerid::String)
    M = (DagScheduler.genv[].meta)::SimpleSchedMeta
    s = sharepath(M, id)
    T = TASKS[]
    canput = withtaskmutex() do
        if !(s in keys(META))
            META[s] = ""
            true
        else
            false
        end
    end
    if canput
        put!(T, annotated)
        M.sharemode.ncreated += 1
        M.sharemode.nshared += 1
        broker_send_sharestats(M)
    end
    nothing
end

function broker_steal_task()
    genv = DagScheduler.genv[]
    (genv === nothing) && (return NoTask)
    M = (genv.meta)::SimpleSchedMeta
    taskid = withtaskmutex() do
        T = TASKS[]
        taskid = NoTask
        if isready(T)
            taskid = take!(T)::TaskIdType
            M.sharemode.nshared -= 1
            M.sharemode.ndeleted += 1
        end
        taskid
    end
    (taskid !== NoTask) && broker_send_sharestats(M)
    taskid
end

function broker_send_sharestats(M)
    sm = M.sharemode
    gen = M.gen
    @schedule begin
        if M.gen <= gen
            put!(RESULTS, (SHAREMODE_KEY, meta_ser((sm.nshared,sm.ncreated,sm.ndeleted))))
            M.gen = time()
        end
    end
    nothing
end

function broker_set_result(k::String, val::String)
    META[k] = val
    put!(RESULTS, (k,val))
    nothing
end

function broker_get_result(k::String)
    META[k]
end

function broker_get_donetasks()
    genv = DagScheduler.genv[]
    (genv === nothing) && (return Set{TaskIdType}())
    M = (genv.meta)::SimpleSchedMeta
    M.donetasks
end
