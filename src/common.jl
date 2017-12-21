const TaskIdType = UInt64

const NoTask = TaskIdType(0)
taskid(id::TaskIdType) = id
taskid(th::Thunk) = TaskIdType(th.id)
#taskid(ch::Chunk) = TaskIdType(hash(ch))
#taskid(executable) = TaskIdType(hash(executable))

function tasklog(env, msg...)
    env.debug && info(env.name, " : ", env.id, " : ", msg...)
end

function taskexception(env, ex, bt)
    xret = CapturedException(ex, bt)
    tasklog(env, "exception ", xret)
    @show xret
    xret
end

function collect_chunks(dag)
    if isa(dag, Chunk)
        return collect(dag)
    elseif isa(dag, Thunk)
       dag.inputs = map(collect_chunks, dag.inputs)
       return dag
    else
       return dag
    end
end

function get_drefs(dag, bucket::Vector{Chunk}=Vector{Chunk}())
   if isa(dag, Chunk)
       if isa(dag.handle, DRef)
           push!(bucket, dag)
       end
   elseif isa(dag, Thunk)
       map(x->get_drefs(x, bucket), dag.inputs)
   end
   bucket
end

#=
get_frefs(dag) = map(chunktodisk, get_drefs(dag))
=#

chunktodisk(chunk) = Chunk(chunk.chunktype, chunk.domain, movetodisk(chunk.handle), chunk.persist)

function walk_dag(dag_node, fn=identity)
    isa(dag_node, Thunk) && (dag_node.inputs = map(x->walk_dag(x, fn), dag_node.inputs))
    fn(dag_node)
end

persist_chunks!(dag) = walk_dag(dag, (node) -> begin
    if isa(node, Chunk)
        node.persist = true
    end
    node
end)

dref_to_fref(dag) = dref_to_fref!(deepcopy(dag))
dref_to_fref!(dag) = walk_dag(dag, (node) -> begin
    if isa(node, Chunk) && isa(node.handle, DRef)
        chunktodisk(node)
    else
        node
    end
end)

function find_task(dag, task::TaskIdType)
    if isa(dag, Thunk)
        if taskid(dag) === task
            return dag
        else
            for inp in dag.inputs
                match = find_task(inp, task)
                (match === nothing) && continue
                return match
            end
        end
    end
    nothing
end
