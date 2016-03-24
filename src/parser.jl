# ----------------- #
# Parsing utilities #
# ----------------- #
call_expr(var, n) = n == 0 ? symbol(var) :
                             symbol(string(var, "_", n > 0 ? "_" : "m", abs(n)))

function eq_expr(ex::Expr, targets::Vector{Symbol}=Symbol[])
    if isempty(targets)
        return Expr(:call, :(-), _parse(ex.args[2]), _parse(ex.args[1]))
    end

    # ensure lhs is in targets
    if !(symbol(ex.args[1]) in targets)
        msg = string("Expected expression of the form `lhs = rhs` ",
                     "where `lhs` is one of $(targets)")
        error(msg)
    end

    Expr(:(=), _parse(ex.args[1]), _parse(ex.args[2]))
end

_parse(x::Symbol) = symbol(string(x, "_"))
_parse(x::Number) = x

function _parse(ex::Expr; targets::Vector{Symbol}=Symbol[])
    @match ex begin
        # translate lhs = rhs  to rhs - lhs
        $(Expr(:(=), :__)) => eq_expr(ex, targets)

        # translate x(n) --> x__n_ and x(-n) -> x_mn_
        var_(shift_Integer) => _parse(call_expr(var, shift))

        # Other func calls. Just parse args. Allows arbitrary Julia functions
        f_(a__) => Expr(:call, f, map(_parse, a)...)

        # the bottom, just insert numbers and symbols
        x_Symbol_Number => x

        _ => error("Not sure what I just saw")
    end
end

_parse(s::AbstractString; kwargs...) = _parse(parse(s); kwargs...)

# -------- #
# Compiler #
# -------- #

function _param_block(sm::ASM)
    params = sm.symbols[:parameters]
    Expr(:block,
         [:(@inbounds $(_parse(params[i])) = p[$i]) for i in 1:length(params)]...)
end

function _aux_block(sm::ASM, shift::Int)
    target = RECIPES[model_spec(sm)][:specs][:auxiliary][:target][1]
    targets = sm.symbols[symbol(target)]
    exprs = sm.equations[:auxiliary]

    # TODO: implement time shift
    Expr(:block,
         [_parse(ex; targets=targets) for ex in exprs]...)
end

function _single_arg_block(sm::ASM, arg_name::Symbol, arg_type::Symbol,
                           shift::Int, Ndim::Int=1)
    if arg_name == :p && arg_type == :parameters
        @assert shift == 0
        return _param_block(sm)
    end

    nms = sm.symbols[arg_type]
    # TODO: extract columns at a time when Ndim > 1
    Expr(:block,
         [:(@inbounds $(_parse("$(nms[i])($(shift))")) = $(arg_name)[$i])
            for i in 1:length(nms)]...)
end

"returns an expression `:(lhs[i] = rhs)`"
_assign_single_el(lhs, rhs, i) = :($lhs[$i] = $rhs)

"Evaluates main expressions in a function group and fills `out` with results"
function _main_body_block(sm::ASM, targets::Vector{Symbol}, exprs::Vector{Expr})
    n_expr = length(exprs)
    parsed_eprs = map(x->_parse(x; targets=targets), exprs)
    assignments = map((rhs,i)->_assign_single_el(:out, rhs, i),
                      parsed_eprs, 1:n_expr)
    func_block = Expr(:block, assignments...)
end

function compile_equation(sm::ASM, func_nm::Symbol)
    # extract spec from recipe
    spec = RECIPES[model_spec(sm)][:specs][func_nm]

    # generate a new type name
    tnm = gensym(func_nm)

    # get expressions from symbolic model
    exprs = sm.equations[func_nm]

    if length(exprs) == 0
        # we are not able to use this equation type. Just create a dummy type
        # and function that throws an error explaining what went wrong
        body = :(error())
        code = quote
            immutable $tnm end
            function Base.call(::$tnm, args...)
                error("Model did not specify functions of type $(func_nm)")
            end

            $tnm()  # see note below
        end
        return code
    end

    # extract information from spec
    target = get(RECIPES[model_spec(sm)][:specs][func_nm], :target, [nothing])[1]
    targets = target === nothing ? Symbol[] : sm.symbols[symbol(target)]
    eqs = spec[:eqs]  # required, so we don't provide a default
    non_aux = filter(x->x[1] != "auxiliaries", eqs)
    only_aux = filter(x->x[1] == "auxiliaries", eqs)
    arg_names = Symbol[symbol(x[3]) for x in non_aux]
    arg_types = Symbol[symbol(x[1]) for x in non_aux]
    arg_shifts = Int[x[2] for x in non_aux]

    # build function block by block
    all_arg_blocks = map((a,b,c) -> _single_arg_block(sm, a, b, c),
                         arg_names, arg_types, arg_shifts)
    arg_block = Expr(:block, all_arg_blocks...)
    main_block = _main_body_block(sm, targets, exprs)

    # construct the body of the function
    body = quote
        $(arg_block)
        $(main_block)
        out  # return out
    end

    # TODO: make sure this is what we want
    typed_args = [Expr(:(::), s, :AbstractVector) for s in arg_names]

    # build the new type and implement methods on Base.call that we need
    code = quote
        immutable $tnm end

        # non-allocating function
        function Base.call(::$tnm, $(typed_args...), out)
            $body  # evaluates equations and populates `out`
        end

        # allocating version
        function Base.call(o::$tnm, $(typed_args...))
            o($(arg_names...), Array(eltype($(arg_names[1])), $(length(exprs))))
        end

        # last line of this block is the singleton instance of the type
        # This means you should do `obj = eval(code)`
        $tnm()
        # TODO: can we use broadcast! to get pretty far towards guvectorize?
    end

    code

end

#=
src = load_file("/Users/sglyon/src/Python/dolo/examples/models/rbc.yaml")
exprs = src["equations"]["arbitrage"]
tnm, code = build_equation(:transition, [:foo, :bar], exprs; eq0=true)
eval(code)
obj = eval(:($(tnm)()))
rho_, zbar_, rho_, z_m1_, e_z_, delta_, k_m1_, i_m1_ = rand(8)
obj(1.0, 2.0, 1.0)

=#
