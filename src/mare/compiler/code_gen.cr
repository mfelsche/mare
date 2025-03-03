require "llvm"
require "random"
require "../ext/llvm" # TODO: get these merged into crystal standard library
require "./code_gen/*"

##
# The purpose of the CodeGen pass is to generate LLVM code (IR) which can
# be used along with LLVM tooling to create an executable program.
#
# This pass does not mutate the Program topology.
# This pass does not mutate the AST.
# This pass does not raise any compilation errors.
# This pass keeps state at the program level.
# This pass produces output state at the program level.
#
class Mare::Compiler::CodeGen
  getter llvm : LLVM::Context
  getter target : LLVM::Target
  getter target_machine : LLVM::TargetMachine
  getter mod : LLVM::Module
  getter builder : LLVM::Builder
  
  class Frame
    getter! llvm_func : LLVM::Function?
    getter gtype : GenType?
    getter gfunc : GenFunc?
    
    setter pony_ctx : LLVM::Value?
    property! receiver_value : LLVM::Value?
    property! continuation_value : LLVM::Value
    
    getter current_locals
    
    def initialize(@g : CodeGen, @llvm_func = nil, @gtype = nil, @gfunc = nil)
      @current_locals = {} of Refer::Local => LLVM::Value
    end
    
    def pony_ctx?
      @pony_ctx.is_a?(LLVM::Value)
    end
    
    def pony_ctx
      @pony_ctx.as(LLVM::Value)
    end
    
    def refer
      @gtype.not_nil!.type_def.refer(@g.ctx)[@gfunc.as(GenFunc).func]
    end
    
    @entry_block : LLVM::BasicBlock?
    def entry_block
      @entry_block ||= llvm_func.basic_blocks.append("entry")
      @entry_block.not_nil!
    end
  end
  
  class GenType
    getter type_def : Reach::Def
    getter gfuncs : Hash(String, GenFunc)
    getter fields : Array(Tuple(String, Reach::Ref))
    getter vtable_size : Int32
    getter desc_type : LLVM::Type
    getter struct_type : LLVM::Type
    getter! desc : LLVM::Value
    getter! singleton : LLVM::Value
    
    def initialize(g : CodeGen, @type_def)
      @gfuncs = Hash(String, GenFunc).new
      
      # Take down info on all fields.
      @fields = @type_def.fields
      
      # Take down info on all functions.
      @vtable_size = 0
      @type_def.each_function(g.ctx).each do |reach_func|
        rf = reach_func.reified
        infer = reach_func.infer
        
        unless rf.func.has_tag?(:hygienic)
          vtable_index = g.ctx.paint[reach_func]
          @vtable_size = (vtable_index + 1) if @vtable_size <= vtable_index
        end
        
        key = rf.func.ident.value
        key += Random::Secure.hex if rf.func.has_tag?(:hygienic)
        key += Random::Secure.hex if @gfuncs.has_key?(key)
        @gfuncs[key] = GenFunc.new(reach_func, vtable_index)
      end
      
      # If we're generating for a type that has no inherent descriptor,
      # we are generating a struct_type for the boxed container that gets used
      # when that value has to be passed as an abstract reference with a desc.
      # In this case, there should be just a single field - the value itself.
      if !type_def.has_desc?
        raise "a value type with no descriptor can't have fields" \
          unless @fields.empty?
        
        @fields << {"VALUE", @type_def.as_ref}
      end
      
      # Generate descriptor type and struct type.
      @desc_type = g.gen_desc_type(@type_def, @vtable_size)
      @struct_type = g.llvm.struct_create_named(@type_def.llvm_name).as(LLVM::Type)
    end
    
    # Generate struct type bodies.
    def gen_struct_type(g : CodeGen)
      g.gen_struct_type(self)
    end
    
    # Generate function declaration return types.
    def gen_func_decl_ret_types(g : CodeGen)
      # Generate associated function declarations, some of which
      # may be referenced in the descriptor global instance below.
      @gfuncs.each_value do |gfunc|
        g.gen_func_decl_ret_type(self, gfunc)
      end
    end
    
    # Generate function declarations.
    def gen_func_decls(g : CodeGen)
      # Generate associated function declarations, some of which
      # may be referenced in the descriptor global instance below.
      @gfuncs.each_value do |gfunc|
        g.gen_func_decl(self, gfunc)
      end
    end
    
    # Generate virtual call table.
    def gen_vtable(g : CodeGen) : Array(LLVM::Value)
      ptr = g.llvm.int8.pointer
      vtable = Array(LLVM::Value).new(@vtable_size, ptr.null)
      @gfuncs.each_value do |gfunc|
        next unless gfunc.vtable_index?
        
        vtable[gfunc.vtable_index] =
          g.llvm.const_bit_cast(gfunc.virtual_llvm_func.to_value, ptr)
      end
      vtable
    end
    
    # Generate the type descriptor value for this type.
    # We skip this for abstract types (traits).
    def gen_desc(g : CodeGen)
      return if @type_def.is_abstract?
      
      @desc = g.gen_desc(self, gen_vtable(g))
    end
    
    # Generate the global singleton value for this type.
    # We skip this for abstract types (traits).
    def gen_singleton(g : CodeGen)
      return if @type_def.is_abstract?
      
      @singleton = g.gen_singleton(self)
    end
    
    # Generate function implementations.
    def gen_func_impls(g : CodeGen)
      return if @type_def.is_abstract?
      
      g.gen_dispatch_impl(self) if @type_def.is_actor?
      g.gen_trace_impl(self)
      
      @gfuncs.each_value do |gfunc|
        g.gen_send_impl(self, gfunc) if gfunc.needs_send?
        g.gen_func_impl(self, gfunc, gfunc.llvm_func)
        
        # A function that his continuation must be generated additional times;
        # once for each yield, each having a different entry path.
        gfunc.continuation_llvm_funcs?.try(&.each { |cont_llvm_func|
          g.gen_func_impl(self, gfunc, cont_llvm_func)
        })
      end
    end
    
    def [](name)
      @gfuncs[name]
    end
    
    def field(name)
      @fields.find(&.first.==(name)).not_nil!.last
    end
    
    def field?(name)
      @fields.find(&.first.==(name)).try(&.last)
    end
    
    def struct_ptr
      @struct_type.pointer
    end
    
    def field_index(name)
      offset = 1 # TODO: not for C-like structs
      offset += 1 if @type_def.has_actor_pad?
      @fields.index { |n, _| n == name }.not_nil! + offset
    end
    
    def each_gfunc
      @gfuncs.each_value
    end
  end
  
  class GenFunc
    getter reach_func : Reach::Func
    getter! vtable_index : Int32
    getter llvm_name : String
    property! llvm_func : LLVM::Function
    property! llvm_func_ret_type : LLVM::Type
    property! virtual_llvm_func : LLVM::Function
    property! send_llvm_func : LLVM::Function
    property! send_msg_llvm_type : LLVM::Type
    property! continuation_info : ContinuationInfo
    property! continuation_type : LLVM::Type
    property! continuation_llvm_func_ptr : LLVM::Type
    property! continuation_llvm_funcs : Array(LLVM::Function)
    property! yield_cc_yield_return_type : LLVM::Type
    property! yield_cc_final_return_type : LLVM::Type
    property! after_yield_blocks : Array(LLVM::BasicBlock)
    
    def initialize(@reach_func, @vtable_index)
      @needs_receiver = type_def.has_state? && !(func.cap.value == "non")
      
      @llvm_name = "#{type_def.llvm_name}#{infer.reified.name}"
      @llvm_name = "#{@llvm_name}.HYGIENIC" if func.has_tag?(:hygienic)
    end
    
    def type_def
      @reach_func.reach_def
    end
    
    def infer
      @reach_func.infer
    end
    
    def func
      infer.func
    end
    
    def calling_convention : Symbol
      list = [] of Symbol
      list << :constructor_cc if func.has_tag?(:constructor)
      list << :error_cc if Jumps.any_error?(func.ident)
      list << :yield_cc if infer.ctx.inventory.yields(func).size > 0
      
      return :simple_cc if list.empty?
      return list.first if list.size == 1
      raise NotImplementedError.new(list)
    end
    
    def needs_receiver?
      @needs_receiver
    end
    
    def needs_send?
      func.has_tag?(:async)
    end
    
    def is_initializer?
      func.has_tag?(:field) && !func.body.nil?
    end
  end
  
  getter! ctx : Context
  
  def initialize
    LLVM.init_x86
    @target_triple = LLVM.default_target_triple
    @target = LLVM::Target.from_triple(@target_triple)
    @target_machine = @target.create_target_machine(@target_triple).as(LLVM::TargetMachine)
    @llvm = LLVM::Context.new
    @mod = @llvm.new_module("main")
    @builder = @llvm.new_builder
    @di = DebugInfo.new(@llvm, @mod, @builder, @target_machine.data_layout)
    
    @default_linkage = LLVM::Linkage::External
    
    @void     = @llvm.void.as(LLVM::Type)
    @ptr      = @llvm.int8.pointer.as(LLVM::Type)
    @pptr     = @llvm.int8.pointer.pointer.as(LLVM::Type)
    @i1       = @llvm.int1.as(LLVM::Type)
    @i1_false = @llvm.int1.const_int(0).as(LLVM::Value)
    @i1_true  = @llvm.int1.const_int(1).as(LLVM::Value)
    @i8       = @llvm.int8.as(LLVM::Type)
    @i16      = @llvm.int16.as(LLVM::Type)
    @i32      = @llvm.int32.as(LLVM::Type)
    @i32_ptr  = @llvm.int32.pointer.as(LLVM::Type)
    @i32_0    = @llvm.int32.const_int(0).as(LLVM::Value)
    @i64      = @llvm.int64.as(LLVM::Type)
    @isize    = @llvm.intptr(@target_machine.data_layout).as(LLVM::Type)
    @f32      = @llvm.float.as(LLVM::Type)
    @f64      = @llvm.double.as(LLVM::Type)
    
    @pony_error_landing_pad_type =
      @llvm.struct([@ptr, @i32], "_.PONY_ERROR_LANDING_PAD_TYPE").as(LLVM::Type)
    @pony_error_personality_fn = @mod.functions.add("ponyint_personality_v0",
      [] of LLVM::Type, @i32).as(LLVM::Function)
    
    @bitwidth = @isize.int_width.to_u.as(UInt32)
    @memcpy = mod.functions.add("llvm.memcpy.p0i8.p0i8.i#{@bitwidth}",
      [@ptr, @ptr, @isize, @i32, @i1], @void).as(LLVM::Function)
    
    @frames = [] of Frame
    @cstring_globals = {} of String => LLVM::Value
    @string_globals = {} of String => LLVM::Value
    @source_code_pos_globals = {} of Source::Pos => LLVM::Value
    @reflection_of_type_globals = {} of GenType => LLVM::Value
    @gtypes = {} of String => GenType
    @try_else_stack = Array(Tuple(
      LLVM::BasicBlock, Array(LLVM::BasicBlock), Array(LLVM::Value)
    )).new
    
    # Pony runtime types.
    @desc = @llvm.struct_create_named("_.DESC").as(LLVM::Type)
    @desc_ptr = @desc.pointer.as(LLVM::Type)
    @obj = @llvm.struct_create_named("_.OBJECT").as(LLVM::Type)
    @obj_ptr = @obj.pointer.as(LLVM::Type)
    @actor_pad = @i8.array(PonyRT::ACTOR_PAD_SIZE).as(LLVM::Type)
    @msg = @llvm.struct([@i32, @i32], "_.MESSAGE").as(LLVM::Type)
    @msg_ptr = @msg.pointer.as(LLVM::Type)
    @trace_fn = LLVM::Type.function([@ptr, @obj_ptr], @void).as(LLVM::Type)
    @trace_fn_ptr = @trace_fn.pointer.as(LLVM::Type)
    @serialise_fn = LLVM::Type.function([@ptr, @obj_ptr, @ptr, @ptr, @i32], @void).as(LLVM::Type) # TODO: fix 4th param type
    @serialise_fn_ptr = @serialise_fn.pointer.as(LLVM::Type)
    @deserialise_fn = LLVM::Type.function([@ptr, @obj_ptr], @void).as(LLVM::Type)
    @deserialise_fn_ptr = @deserialise_fn.pointer.as(LLVM::Type)
    @custom_serialise_space_fn = LLVM::Type.function([@obj_ptr], @i64).as(LLVM::Type)
    @custom_serialise_space_fn_ptr = @serialise_fn.pointer.as(LLVM::Type)
    @custom_deserialise_fn = LLVM::Type.function([@obj_ptr, @ptr], @void).as(LLVM::Type)
    @custom_deserialise_fn_ptr = @deserialise_fn.pointer.as(LLVM::Type)
    @dispatch_fn = LLVM::Type.function([@ptr, @obj_ptr, @msg_ptr], @void).as(LLVM::Type)
    @dispatch_fn_ptr = @dispatch_fn.pointer.as(LLVM::Type)
    @final_fn = LLVM::Type.function([@obj_ptr], @void).as(LLVM::Type)
    @final_fn_ptr = @final_fn.pointer.as(LLVM::Type)
    
    # Finish defining the forward-declared @desc and @obj types
    gen_desc_basetype
    @obj.struct_set_body([@desc_ptr])
    
    # Pony runtime function declarations.
    gen_runtime_decls
  end
  
  def frame
    @frames.last
  end
  
  def func_frame
    @frames.reverse_each.find { |f| f.llvm_func? }.not_nil!
  end
  
  def gen_frame
    @frames.each.find { |f| f.llvm_func? }.not_nil!
  end
  
  def abi_size_of(llvm_type : LLVM::Type)
    @target_machine.data_layout.abi_size(llvm_type)
  end
  
  def type_of(expr : AST::Node, in_gfunc : GenFunc? = nil)
    in_gfunc ||= func_frame.gfunc.not_nil!
    ctx.reach[in_gfunc.infer.resolve(expr)]
  end
  
  def llvm_type_of(gtype : GenType)
    llvm_type_of(gtype.type_def.as_ref) # TODO: this is backwards - defs should have a llvm_use_type of their own, with refs delegating to that implementation when there is a singular meta_type
  end
  
  def llvm_type_of(expr : AST::Node, in_gfunc : GenFunc? = nil)
    llvm_type_of(type_of(expr, in_gfunc))
  end
  
  def llvm_mem_type_of(expr : AST::Node, in_gfunc : GenFunc? = nil)
    llvm_mem_type_of(type_of(expr, in_gfunc))
  end
  
  def llvm_type_of(ref : Reach::Ref)
    case ref.llvm_use_type
    when :i1 then @i1
    when :i8 then @i8
    when :i16 then @i16
    when :i32 then @i32
    when :i64 then @i64
    when :f32 then @f32
    when :f64 then @f64
    when :ptr then llvm_type_of(ref.single_def!(ctx).cpointer_type_arg).pointer
    when :isize then @isize
    when :struct_ptr then
      @gtypes[ctx.reach[ref.single!].llvm_name].struct_ptr
    when :object_ptr then
      @obj_ptr
    else raise NotImplementedError.new(ref.llvm_use_type)
    end
  end
  
  def llvm_mem_type_of(ref : Reach::Ref)
    case ref.llvm_mem_type
    when :i1 then @i1
    when :i8 then @i8
    when :i16 then @i16
    when :i32 then @i32
    when :i64 then @i64
    when :f32 then @f32
    when :f64 then @f64
    when :ptr then llvm_type_of(ref.single_def!(ctx).cpointer_type_arg).pointer
    when :isize then @isize
    when :struct_ptr then
      @gtypes[ctx.reach[ref.single!].llvm_name].struct_ptr
    when :object_ptr then
      @obj_ptr
    else raise NotImplementedError.new(ref.llvm_mem_type)
    end
  end
  
  def gtype_of(reach_ref : Reach::Ref)
    @gtypes[ctx.reach[reach_ref.single!].llvm_name]
  end
  
  def gtype_of(expr : AST::Node, in_gfunc : GenFunc? = nil)
    gtype_of(type_of(expr, in_gfunc))
  end
  
  def gtypes_of(expr : AST::Node, in_gfunc : GenFunc? = nil)
    type_of(expr, in_gfunc).each_defn.map do |defn|
      llvm_name = ctx.reach[defn].llvm_name
      @gtypes[llvm_name]
    end.to_a
  end
  
  def pony_ctx
    # Return the stored value if we have it cached for this function already.
    return func_frame.pony_ctx if func_frame.pony_ctx?
    
    gen_at_entry do
      # Call the pony_ctx function and save the value to refer to it later.
      func_frame.pony_ctx = @builder.call(@mod.functions["pony_ctx"], "PONY_CTX")
    end
  end
  
  def run(ctx : Context)
    @ctx = ctx
    @di.ctx = ctx
    
    # Generate all type descriptors and function declarations.
    ctx.reach.each_type_def.each do |type_def|
      @gtypes[type_def.llvm_name] = GenType.new(self, type_def)
    end
    
    # Generate all struct types.
    @gtypes.each_value(&.gen_struct_type(self))
    
    # Generate all function declaration return types.
    @gtypes.each_value(&.gen_func_decl_ret_types(self))
    
    # Generate all function declarations.
    @gtypes.each_value(&.gen_func_decls(self))
    
    # Generate all global descriptor instances.
    @gtypes.each_value(&.gen_desc(self))
    
    # Generate all global values associated with this type.
    @gtypes.each_value(&.gen_singleton(self))
    
    # Generate all function implementations.
    @gtypes.each_value(&.gen_func_impls(self))
    
    # Generate the internal main function.
    gen_main
    
    # Generate the wrapper main function for the JIT.
    gen_wrapper
    
    # Finish up debugging info.
    @di.finish
    
    # Run LLVM sanity checks on the generated module.
    begin
      @mod.verify
    rescue ex
      @mod.dump
      raise ex
    end
  end
  
  def gen_wrapper
    # Declare the wrapper function for the JIT.
    wrapper = @mod.functions.add("__mare_jit", ([] of LLVM::Type), @i32)
    wrapper.linkage = LLVM::Linkage::External
    
    # Create a basic block to hold the implementation of the main function.
    bb = wrapper.basic_blocks.append("entry")
    @builder.position_at_end bb
    
    # Construct the following arguments to pass to the main function:
    # i32 argc = 0, i8** argv = ["marejit", NULL], i8** envp = [NULL]
    argc = @i32.const_int(1)
    argv = @builder.alloca(@i8.pointer.array(2), "argv")
    envp = @builder.alloca(@i8.pointer.array(1), "envp")
    argv_0 = @builder.inbounds_gep(argv, @i32_0, @i32_0, "argv_0")
    argv_1 = @builder.inbounds_gep(argv, @i32_0, @i32.const_int(1), "argv_1")
    envp_0 = @builder.inbounds_gep(envp, @i32_0, @i32_0, "envp_0")
    @builder.store(gen_cstring("marejit"), argv_0)
    @builder.store(@ptr.null, argv_1)
    @builder.store(@ptr.null, envp_0)
    
    # Call the main function with the constructed arguments.
    res = @builder.call(@mod.functions["main"], [argc, argv_0, envp_0], "res")
    @builder.ret(res)
  end
  
  def gen_main
    # Declare the main function.
    main = @mod.functions.add("main", [@i32, @pptr, @pptr], @i32)
    main.linkage = LLVM::Linkage::External
    
    gen_func_start(main)
    
    argc = main.params[0].tap &.name=("argc")
    argv = main.params[1].tap &.name=("argv")
    envp = main.params[2].tap &.name=("envp")
    
    # Call pony_init, letting it optionally consume some of the CLI args,
    # giving us a new value for argc and a mutated argv array.
    argc = @builder.call(@mod.functions["pony_init"], [@i32.const_int(1), argv], "argc")
    
    # Get the current pony_ctx and hold on to it.
    pony_ctx = @builder.call(@mod.functions["pony_ctx"], "ctx")
    func_frame.pony_ctx = pony_ctx
    
    # Create the main actor and become it.
    main_actor = gen_alloc_actor(@gtypes["Main"], "main", true)
    
    # TODO: Create the Env from argc, argv, and envp.
    env = gen_alloc(@gtypes["Env"], "env")
    @builder.call(@gtypes["Env"]["_create"].llvm_func, [env])
    # TODO: @builder.call(@gtypes["Env"]["_create"].llvm_func,
    #   [argc, @builder.bit_cast(argv, @ptr), @builder.bitcast(envp, @ptr)])
    
    # TODO: Run primitive initialisers using the main actor's heap.
    
    # Send the env in a message to the main actor's constructor
    @builder.call(@gtypes["Main"]["new"].send_llvm_func, [main_actor, env])
    
    # Start the runtime.
    start_success = @builder.call(@mod.functions["pony_start"], [
      @i1.const_int(0),
      @i32_ptr.null,
      @ptr.null, # TODO: pony_language_features_init_t*
    ], "start_success")
    
    # Branch based on the value of `start_success`.
    start_fail_block = gen_block("start_fail")
    post_block = gen_block("post")
    @builder.cond(start_success, post_block, start_fail_block)
    
    # On failure, just write a failure message then continue to the post_block.
    @builder.position_at_end(start_fail_block)
    @builder.call(@mod.functions["puts"], [
      gen_cstring("Error: couldn't start the runtime!")
    ])
    @builder.br(post_block)
    
    # On success (or after running the failure block), do the following:
    @builder.position_at_end(post_block)
    
    # TODO: Run primitive finalizers.
    
    # Become nothing (stop being the main actor).
    @builder.call(@mod.functions["pony_become"], [
      func_frame.pony_ctx,
      @obj_ptr.null,
    ])
    
    # Get the program's chosen exit code (or 0 by default), but override
    # it with -1 if we failed to start the runtime.
    exitcode = @builder.call(@mod.functions["pony_get_exitcode"], "exitcode")
    ret = @builder.select(start_success, exitcode, @i32.const_int(-1), "ret")
    @builder.ret(ret)
    
    gen_func_end
    
    main
  end
  
  def gen_func_start(llvm_func, gtype : GenType? = nil, gfunc : GenFunc? = nil)
    @frames << Frame.new(self, llvm_func, gtype, gfunc)
    
    # Add debug info for this function
    @di.func_start(gfunc, llvm_func) if gfunc
    
    # Start building from the entry block.
    @builder.position_at_end(func_frame.entry_block)
    
    # We have some extra work to do here if this is a yielding function.
    if gfunc && gfunc.calling_convention == :yield_cc
      # We need to pre-declare the code blocks that follow each yield statement.
      gfunc.after_yield_blocks = [] of LLVM::BasicBlock
      ctx.inventory.yields(gfunc.func).size.times do |index|
        gfunc.after_yield_blocks << gen_block("after_yield_#{index + 1}")
      end
      
      # For the continuation functions, we will jump directly to the block
      # that follows the yield statement that last ran in the previous call.
      # We will get a non-nil yield_index here if this is a continuation call.
      yield_index = gfunc.continuation_llvm_funcs.index(llvm_func)
      if yield_index.nil?
        # If this isn't a continuation function, we have to create the object
        # that will hold the continuation data, since it starts right here.
        gfunc.continuation_info.initial_cont(func_frame)
      else
        # If this *is* a continuation function, we need to grab the object
        # holding the continuation data and extract receiver, locals, etc.
        gfunc.continuation_info.continue_cont(func_frame)
        
        # We are jumping to the after-yield block here, which means that all
        # code that is about to be generated will be in an unused code block.
        # So we set up a block called "unused_entry" to hold that code, then
        # return from this function early to avoid generating the code below
        # that will fetch parameters into local geps.
        @builder.br(gfunc.after_yield_blocks[yield_index])
        unused_entry_block = gen_block("unused_entry")
        @builder.position_at_end(unused_entry_block)
        return
      end
    end
    
    # Store each parameter in an alloca (or the continuation, if present)
    if gfunc && !gfunc.func.has_tag?(:ffi)
      gfunc.func.params.try(&.terms.each do |param|
        ref = func_frame.refer[param].as(Refer::Local)
        param_idx = ref.param_idx.not_nil!
        param_idx -= 1 unless gfunc.needs_receiver?
        value = frame.llvm_func.params[param_idx]
        gep = gen_local_gep(ref, value.type)
        func_frame.current_locals[ref] = gep
        @builder.store(value, gep)
      end)
    end
  end
  
  def gen_func_end(gfunc = nil)
    @di.func_end if gfunc
    
    raise "invalid try else stack" unless @try_else_stack.empty?
    
    @frames.pop
  end
  
  def gen_within_foreign_frame(gtype : GenType, gfunc : GenFunc)
    @frames << Frame.new(self, gfunc.llvm_func, gtype, gfunc)
    
    result = yield
    
    @frames.pop
    
    result
  end
  
  def gen_block(name)
    frame.llvm_func.basic_blocks.append(name)
  end
  
  def gen_func_decl_ret_type(gtype, gfunc)
    gfunc.continuation_info = ContinuationInfo.new(self, gtype, gfunc)
    
    # If this is a yielding function, we must first declare the type that will
    # be used to hold continuation data for the subsequent continuing calls.
    if gfunc.calling_convention == :yield_cc
      gfunc.continuation_type =
        @llvm.struct_create_named("#{gfunc.llvm_name}.CONTINUATION")
    end
    
    # Determine the LLVM type to return, based on the calling convention.
    simple_ret_type = llvm_type_of(gfunc.reach_func.signature.ret)
    gfunc.llvm_func_ret_type =
      case gfunc.calling_convention
      when :constructor_cc
        @void
      when :simple_cc
        simple_ret_type
      when :error_cc
        llvm.struct([simple_ret_type, @i1])
      when :yield_cc
        cont_ptr = gfunc.continuation_type.pointer
        
        # Gather the LLVM::Types to use for the yield out values.
        yield_out_types = gfunc.infer.yield_out_resolved.map do |resolved|
          llvm_type_of(ctx.reach[resolved])
        end
        
        # Define two different return types - one for the yield returns
        # and one for the final return when all yielding is done.
        # The former contains the "yield out" values and the latter has the
        # actual return value declared or inferred for this function.
        y_t = gfunc.yield_cc_yield_return_type = llvm.struct([cont_ptr] + yield_out_types)
        f_t = gfunc.yield_cc_final_return_type = llvm.struct([cont_ptr, simple_ret_type])
        
        # Determine the byte size of the larger type of the two.
        max_size = [abi_size_of(y_t), abi_size_of(f_t)].max
        
        # Pad the yield return type with extra bytes as needed.
        while abi_size_of(y_t) < max_size
          y_t = gfunc.yield_cc_yield_return_type = \
            llvm.struct(y_t.struct_element_types + [@isize])
        end
        
        # Pad the final return type with extra bytes as needed.
        while abi_size_of(f_t) < max_size
          f_t = gfunc.yield_cc_final_return_type = \
            llvm.struct(f_t.struct_element_types + [@isize])
        end
        
        # The generic return type of the two is a struct containing just the
        # continuation data, with the remaining size filled by padding bytes.
        opaque_t = llvm.struct([cont_ptr])
        while abi_size_of(opaque_t) < max_size
          opaque_t = llvm.struct(opaque_t.struct_element_types + [@isize])
        end
        
        # As a sanity check, confirm that the resulting sizes are the same.
        raise "Failed to balance yield return struct sizes" unless \
          (abi_size_of(opaque_t) == abi_size_of(y_t)) && \
          (abi_size_of(opaque_t) == abi_size_of(f_t))
        
        opaque_t
      else
        raise NotImplementedError.new(gfunc.calling_convention)
      end
  end
  
  def gen_func_decl(gtype, gfunc)
    ret_type = gfunc.llvm_func_ret_type
    
    # Get the LLVM types to use for the parameter types.
    param_types = [] of LLVM::Type
    mparam_types = [] of LLVM::Type if gfunc.needs_send?
    gfunc.reach_func.signature.params.map do |param|
      param_types << llvm_type_of(param)
      mparam_types << llvm_mem_type_of(param) if mparam_types
    end
    
    # Add implicit receiver parameter if needed.
    param_types.unshift(llvm_type_of(gtype)) if gfunc.needs_receiver?
    
    # Store the function declaration.
    gfunc.llvm_func = @mod.functions.add(gfunc.llvm_name, param_types, ret_type)
    
    # Choose the strategy for the function that goes in the virtual table.
    # The virtual table is used for calling functions indirectly, and always
    # has an object-style receiver as the first parameter, for consistency.
    # However, some functions expect no receiver or expect a raw machine value,
    # so we may need a wrapper function that handles this case.
    gfunc.virtual_llvm_func =
      if !gfunc.needs_receiver?
        # If we didn't use a receiver parameter in the function signature,
        # we need to create a wrapper method for the virtual table that
        # includes a receiver parameter, but throws it away without using it.
        vtable_name = "#{gfunc.llvm_name}.VIRTUAL"
        vparam_types = param_types.dup
        vparam_types.unshift(gtype.struct_ptr)
        
        @mod.functions.add vtable_name, vparam_types, ret_type do |fn|
          next if gtype.type_def.is_abstract?
          
          gen_func_start(fn)
          
          forward_args =
            (vparam_types.size - 1).times.map { |i| fn.params[i + 1] }.to_a
          
          @builder.ret @builder.call(gfunc.llvm_func, forward_args)
          
          gen_func_end
        end
      elsif param_types.first != gtype.struct_ptr
        # If the receiver parameter type doesn't match the struct pointer,
        # we assume it is a boxed machine value, so we need a wrapper function
        # that will unwrap the raw machine value to use as the receiver.
        elem_types = gtype.struct_type.struct_element_types
        raise "expected the receiver type to be a raw machine value" \
          unless elem_types.size == 2 && elem_types[1] == param_types.first
        
        vtable_name = "#{gfunc.llvm_name}.VIRTUAL"
        vparam_types = param_types.dup
        vparam_types.shift
        vparam_types.unshift(gtype.struct_ptr)
        
        @mod.functions.add vtable_name, vparam_types, ret_type do |fn|
          next if gtype.type_def.is_abstract?
          
          gen_func_start(fn)
          
          forward_args =
            (vparam_types.size - 1).times.map { |i| fn.params[i + 1] }.to_a
          forward_args.unshift(gen_unboxed(fn.params[0], gtype))
          
          @builder.ret @builder.call(gfunc.llvm_func, forward_args)
          
          gen_func_end
        end
      else
        # Otherwise the function needs no wrapper; it can be naked in the table.
        gfunc.llvm_func
      end
    
    # If this is an async function, we need to generate a wrapper that sends
    # it as a message to be handled asynchronously by the dispatch function.
    # This is also the function that should go in the virtual table.
    if gfunc.needs_send?
      send_name = "#{gfunc.llvm_name}.SEND"
      msg_name = "#{gfunc.llvm_name}.SEND.MSG"
      
      # We'll fill in the implementation of this later, in gen_send_impl.
      gfunc.virtual_llvm_func = gfunc.send_llvm_func =
        @mod.functions.add(send_name, param_types, @gtypes["None"].struct_ptr)
      
      # We also need to create a message type to use in the send operation.
      gfunc.send_msg_llvm_type =
        @llvm.struct([@i32, @i32, @ptr] + mparam_types.not_nil!, msg_name)
    end
    
    # If this is a yielding function, we need to generate the alternate
    # versions of it, each with their own different entrypoint block
    # that will take the control flow to continuing where that yield was.
    if gfunc.calling_convention == :yield_cc
      continue_param_types = [
        gfunc.continuation_type.pointer, # TODO: pass by value instead of by pointer
        llvm_type_of(ctx.reach[gfunc.infer.yield_in_resolved]),
      ]
      
      # Before declaring the continue functions themselves, we also declare
      # the generic function pointer type that covers all of them.
      # This is needed so that the functions can be called via function pointer.
      gfunc.continuation_llvm_func_ptr =
        LLVM::Type.function(continue_param_types, ret_type).pointer
      
      # Now declare the continue functions, all with that same signature.
      gfunc.continuation_llvm_funcs =
        ctx.inventory.yields(gfunc.func).each_index.map do |index|
          continue_name = "#{gfunc.llvm_name}.CONTINUE.#{index + 1}"
          @mod.functions.add(continue_name, continue_param_types, ret_type)
        end.to_a
      
      gfunc.continuation_type.struct_set_body(gfunc.continuation_info.struct_element_types)
    end
  end
  
  def gen_func_impl(gtype, gfunc, llvm_func)
    return gen_intrinsic(gtype, gfunc, llvm_func) if gfunc.func.has_tag?(:compiler_intrinsic)
    return gen_ffi_impl(gtype, gfunc, llvm_func) if gfunc.func.has_tag?(:ffi)
    
    # Fields with no initializer body can be skipped.
    return if gfunc.func.has_tag?(:field) && gfunc.func.body.nil?
    
    gen_func_start(llvm_func, gtype, gfunc)
    
    # Set a receiver value (the value of the self in this function).
    # Skip this in the event that it was already set in gen_func_start.
    unless func_frame.receiver_value?
      func_frame.receiver_value =
        if gfunc.needs_receiver?
          llvm_func.params[0]
        elsif gtype.singleton?
          gtype.singleton
        end
    end
    
    # If this is a constructor, first assign any field initializers.
    if gfunc.func.has_tag?(:constructor)
      gtype.fields.each do |name, _|
        init_func =
          gtype.each_gfunc.find do |gfunc|
            gfunc.func.ident.value == name &&
            gfunc.func.has_tag?(:field) &&
            !gfunc.func.body.nil?
          end
        next if init_func.nil?
        
        call_args = [func_frame.receiver_value]
        init_value = @builder.call(init_func.llvm_func, call_args)
        gen_field_store(name, init_value)
      end
    end
    
    # Now generate code for the expressions in the function body.
    last_expr = nil
    last_value = nil
    gfunc.func.body.not_nil!.terms.each do |expr|
      last_expr = expr
      last_value = gen_expr(expr, gfunc.func.has_tag?(:constant))
    end
    last_value ||= gen_none
    
    # For field initializers, make sure the LLVM type of the return value
    # matches the LLVM return type declared in the function head.
    # TODO: Why only field initializers? Why not all functions?
    if gfunc.func.has_tag?(:field)
      return_type = gfunc.llvm_func.return_type
      last_value = gen_assign_cast(last_value, return_type, last_expr)
    end
    
    unless Jumps.away?(gfunc.func.body.not_nil!)
      case gfunc.calling_convention
      when :constructor_cc
        @builder.ret
      when :simple_cc
        @builder.ret(last_value)
      when :error_cc
        gen_return_using_error_cc(last_value, last_expr, false)
      when :yield_cc
        gen_final_return_using_yield_cc(last_value)
      else
        raise NotImplementedError.new(gfunc.calling_convention)
      end
    end
    
    gen_func_end(gfunc)
  end
  
  def gen_ffi_decl(gfunc)
    params = gfunc.func.params.not_nil!.terms.map do |param|
      llvm_type_of(param, gfunc)
    end
    ret = llvm_type_of(gfunc.func.ret.not_nil!, gfunc)
    
    ffi_link_name = gfunc.func.metadata[:ffi_link_name].as(String)
    
    # Prevent double-declaring for common FFI functions already known to us.
    llvm_ffi_func = @mod.functions[ffi_link_name]?
    if llvm_ffi_func
      # TODO: verify that parameter types and return type are compatible
      return @mod.functions[ffi_link_name]
    end
    
    @mod.functions.add(ffi_link_name, params, ret)
  end
  
  def gen_ffi_impl(gtype, gfunc, llvm_func)
    llvm_ffi_func = gen_ffi_decl(gfunc)
    
    gen_func_start(llvm_func, gtype, gfunc)
    
    param_count = llvm_func.params.size
    args = param_count.times.map { |i| llvm_func.params[i] }.to_a
    
    case gfunc.calling_convention
    when :simple_cc
      value = @builder.call llvm_ffi_func, args
      value = gen_none if llvm_ffi_func.return_type == @void
      @builder.ret(value)
    when :error_cc
      then_block = gen_block("invoke_then")
      else_block = gen_block("invoke_else")
      value = @builder.invoke llvm_ffi_func, args, then_block, else_block
      value = gen_none if llvm_ffi_func.return_type == @void
      
      # In the else block, make a landing pad to catch the pony-style error,
      # then return an error using our error calling convention.
      @builder.position_at_end(else_block)
      @builder.landing_pad(
        @pony_error_landing_pad_type,
        @pony_error_personality_fn,
        [] of LLVM::Value,
      )
      gen_return_using_error_cc(gen_none, nil, true)
      
      # In the then block, return the value using our error calling convention.
      @builder.position_at_end(then_block)
      gen_return_using_error_cc(value, nil, false)
    else
      raise NotImplementedError.new(gfunc.calling_convention)
    end
    
    gen_func_end(gfunc)
  end
  
  def gen_intrinsic_cpointer(gtype, gfunc, llvm_func)
    gen_func_start(llvm_func)
    params = llvm_func.params
    
    llvm_type = llvm_type_of(gtype)
    elem_llvm_type = llvm_mem_type_of(gtype.type_def.cpointer_type_arg)
    elem_size_value = abi_size_of(elem_llvm_type)
    
    @builder.ret \
      case gfunc.func.ident.value
      when "null", "_null"
        llvm_type.null
      when "_alloc"
        llvm_func.add_attribute(LLVM::Attribute::NoAlias, LLVM::AttributeIndex::ReturnIndex)
        llvm_func.add_attribute(LLVM::Attribute::DereferenceableOrNull, LLVM::AttributeIndex::ReturnIndex, elem_size_value)
        llvm_func.add_attribute(LLVM::Attribute::Alignment, LLVM::AttributeIndex::ReturnIndex, PonyRT::HEAP_MIN)
        
        @builder.bit_cast(
          @builder.call(@mod.functions["pony_alloc"], [
            pony_ctx,
            @builder.mul(params[0], @isize.const_int(elem_size_value)),
          ]),
          llvm_type,
        )
      when "_realloc"
        llvm_func.add_attribute(LLVM::Attribute::NoAlias, LLVM::AttributeIndex::ReturnIndex)
        llvm_func.add_attribute(LLVM::Attribute::DereferenceableOrNull, LLVM::AttributeIndex::ReturnIndex, elem_size_value)
        llvm_func.add_attribute(LLVM::Attribute::Alignment, LLVM::AttributeIndex::ReturnIndex, PonyRT::HEAP_MIN)
        
        @builder.bit_cast(
          @builder.call(@mod.functions["pony_realloc"], [
            pony_ctx,
            @builder.bit_cast(params[0], @ptr),
            @builder.mul(params[1], @isize.const_int(elem_size_value)),
          ]),
          llvm_type,
        )
      when "_unsafe"
        params[0]
      when "_offset"
        @builder.bit_cast(
          @builder.inbounds_gep(
            @builder.bit_cast(params[0], elem_llvm_type.pointer),
            params[1]
          ),
          params[0].type
        )
      when "_get_at"
        gep = @builder.inbounds_gep(params[0], params[1])
        @builder.load(gep)
      when "_get_at_no_alias"
        gep = @builder.inbounds_gep(params[0], params[1])
        @builder.load(gep)
      when "_assign_at"
        gep = @builder.inbounds_gep(params[0], params[1])
        new_value = params[2]
        @builder.store(new_value, gep)
        new_value
      when "_displace_at"
        gep = @builder.inbounds_gep(params[0], params[1])
        new_value = params[2]
        old_value = @builder.load(gep)
        @builder.store(new_value, gep)
        old_value
      when "_copy_to"
        @builder.call(@memcpy, [
          @builder.bit_cast(params[1], @ptr),
          @builder.bit_cast(params[0], @ptr),
          @builder.mul(
            params[2],
            @isize.const_int(elem_size_value),
          ),
          @i32.const_int(1),
          @i1.const_int(0),
        ])
        gen_none
      when "_compare"
        @builder.call(
          @mod.functions["memcmp"],
          [params[0], params[1], params[2]],
        )
      when "_hash"
        @builder.call(
          @mod.functions["ponyint_hash_block"],
          [params[0], params[1]],
        )
      when "is_null"
        @builder.is_null(params[0])
      when "is_not_null"
        @builder.is_not_null(params[0])
      when "usize"
        @builder.ptr_to_int(params[0], @isize)
      when "from_usize"
        @builder.int_to_ptr(params[0], @ptr)
      else
        raise NotImplementedError.new(gfunc.func.ident.value)
      end
    
    gen_func_end
  end
  
  def gen_intrinsic_platform(gtype, gfunc, llvm_func)
    gen_func_start(llvm_func)
    params = llvm_func.params
    
    @builder.ret \
      case gfunc.func.ident.value
      when "ilp32"
        gen_bool(abi_size_of(@isize) == 4)
      when "lp64"
        gen_bool(abi_size_of(@isize) == 8)
      else
        raise NotImplementedError.new(gfunc.func.ident.value)
      end
    
    gen_func_end
  end
  
  def gen_intrinsic(gtype, gfunc, llvm_func)
    return gen_intrinsic_cpointer(gtype, gfunc, llvm_func) if gtype.type_def.is_cpointer?
    return gen_intrinsic_platform(gtype, gfunc, llvm_func) if gtype.type_def.is_platform?
    
    raise NotImplementedError.new(gtype.type_def) \
      unless gtype.type_def.is_numeric?
    
    gen_func_start(llvm_func)
    params = llvm_func.params
    
    @builder.ret \
      case gfunc.func.ident.value
      when "bit_width"
        @i8.const_int(
          abi_size_of(llvm_type_of(gtype)) * 8
        )
      when "zero"
        if gtype.type_def.is_floating_point_numeric?
          case bit_width_of(gtype)
          when 32 then llvm_type_of(gtype).const_float(0)
          when 64 then llvm_type_of(gtype).const_double(0)
          else raise NotImplementedError.new(bit_width_of(gtype))
          end
        else
          llvm_type_of(gtype).const_int(0)
        end
      when "u8" then gen_numeric_conv(gtype, @gtypes["U8"], params[0])
      when "u16" then gen_numeric_conv(gtype, @gtypes["U16"], params[0])
      when "u32" then gen_numeric_conv(gtype, @gtypes["U32"], params[0])
      when "u64" then gen_numeric_conv(gtype, @gtypes["U64"], params[0])
      when "usize" then gen_numeric_conv(gtype, @gtypes["USize"], params[0])
      when "i8" then gen_numeric_conv(gtype, @gtypes["I8"], params[0])
      when "i16" then gen_numeric_conv(gtype, @gtypes["I16"], params[0])
      when "i32" then gen_numeric_conv(gtype, @gtypes["I32"], params[0])
      when "i64" then gen_numeric_conv(gtype, @gtypes["I64"], params[0])
      when "isize" then gen_numeric_conv(gtype, @gtypes["ISize"], params[0])
      when "f32" then gen_numeric_conv(gtype, @gtypes["F32"], params[0])
      when "f64" then gen_numeric_conv(gtype, @gtypes["F64"], params[0])
      when "==" then
        if gtype.type_def.is_floating_point_numeric?
          @builder.fcmp(LLVM::RealPredicate::OEQ, params[0], params[1])
        else
          @builder.icmp(LLVM::IntPredicate::EQ, params[0], params[1])
        end
      when "!=" then
        if gtype.type_def.is_floating_point_numeric?
          @builder.fcmp(LLVM::RealPredicate::ONE, params[0], params[1])
        else
          @builder.icmp(LLVM::IntPredicate::NE, params[0], params[1])
        end
      when "<" then
        if gtype.type_def.is_floating_point_numeric?
          @builder.fcmp(LLVM::RealPredicate::OLT, params[0], params[1])
        elsif gtype.type_def.is_signed_numeric?
          @builder.icmp(LLVM::IntPredicate::SLT, params[0], params[1])
        else
          @builder.icmp(LLVM::IntPredicate::ULT, params[0], params[1])
        end
      when "<=" then
        if gtype.type_def.is_floating_point_numeric?
          @builder.fcmp(LLVM::RealPredicate::OLE, params[0], params[1])
        elsif gtype.type_def.is_signed_numeric?
          @builder.icmp(LLVM::IntPredicate::SLE, params[0], params[1])
        else
          @builder.icmp(LLVM::IntPredicate::ULE, params[0], params[1])
        end
      when ">" then
        if gtype.type_def.is_floating_point_numeric?
          @builder.fcmp(LLVM::RealPredicate::OGT, params[0], params[1])
        elsif gtype.type_def.is_signed_numeric?
          @builder.icmp(LLVM::IntPredicate::SGT, params[0], params[1])
        else
          @builder.icmp(LLVM::IntPredicate::UGT, params[0], params[1])
        end
      when ">=" then
        if gtype.type_def.is_floating_point_numeric?
          @builder.fcmp(LLVM::RealPredicate::OGE, params[0], params[1])
        elsif gtype.type_def.is_signed_numeric?
          @builder.icmp(LLVM::IntPredicate::SGE, params[0], params[1])
        else
          @builder.icmp(LLVM::IntPredicate::UGE, params[0], params[1])
        end
      when "+" then
        if gtype.type_def.is_floating_point_numeric?
          @builder.fadd(params[0], params[1])
        else
          @builder.add(params[0], params[1])
        end
      when "-" then
        if gtype.type_def.is_floating_point_numeric?
          @builder.fsub(params[0], params[1])
        else
          @builder.sub(params[0], params[1])
        end
      when "*" then
        if gtype.type_def.is_floating_point_numeric?
          @builder.fmul(params[0], params[1])
        else
          @builder.mul(params[0], params[1])
        end
      when "/", "%" then
        if gtype.type_def.is_floating_point_numeric?
          if gfunc.func.ident.value == "/"
            @builder.fdiv(params[0], params[1])
          else
            @builder.frem(params[0], params[1])
          end
        else # we need to some extra work to avoid an undefined result value
          params[0].name = "numerator"
          params[1].name = "denominator"
          
          llvm_type = llvm_type_of(gtype)
          zero = llvm_type.const_int(0)
          nonzero_block = gen_block(".div.nonzero")
          nonoverflow_block = gen_block(".div.nonoverflow") \
            if gtype.type_def.is_signed_numeric?
          after_block = gen_block(".div.after")
          
          blocks = [] of LLVM::BasicBlock
          values = [] of LLVM::Value
          
          # Return zero if dividing by zero.
          nonzero = @builder.icmp LLVM::IntPredicate::NE, params[1], zero,
            "#{params[1].name}.nonzero"
          @builder.cond(nonzero, nonzero_block, after_block)
          blocks << @builder.insert_block
          values << zero
          @builder.position_at_end(nonzero_block)
          
          # If signed, return zero if this operation would overflow.
          # This happens for exactly one case in each signed integer type.
          # In `I8`, the overflow case is `-128 / -1`, which would be 128.
          if gtype.type_def.is_signed_numeric?
            bad = @builder.not(zero)
            denom_good = @builder.icmp LLVM::IntPredicate::NE, params[1], bad,
              "#{params[1].name}.nonoverflow"
            
            bits = llvm_type.const_int(bit_width_of(gtype) - 1)
            bad = @builder.shl(bad, bits)
            numer_good = @builder.icmp LLVM::IntPredicate::NE, params[0], bad,
              "#{params[0].name}.nonoverflow"
            
            either_good = @builder.or(numer_good, denom_good, "nonoverflow")
            
            @builder.cond(either_good, nonoverflow_block.not_nil!, after_block)
            blocks << @builder.insert_block
            values << zero
            @builder.position_at_end(nonoverflow_block.not_nil!)
          end
          
          # Otherwise, compute the result.
          result =
            case {gtype.type_def.is_signed_numeric?, gfunc.func.ident.value}
            when {true, "/"} then @builder.sdiv(params[0], params[1])
            when {true, "%"} then @builder.srem(params[0], params[1])
            when {false, "/"} then @builder.udiv(params[0], params[1])
            when {false, "%"} then @builder.urem(params[0], params[1])
            else raise NotImplementedError.new(gtype.type_def.llvm_name)
            end
          result.name = "result"
          @builder.br(after_block)
          blocks << @builder.insert_block
          values << result
          @builder.position_at_end(after_block)
          
          # Get the final result, which may be zero from one of the pre-checks.
          @builder.phi(llvm_type, blocks, values, "phidiv")
        end
      when "bit_and"
        raise "bit_and float" if gtype.type_def.is_floating_point_numeric?
        @builder.and(params[0], params[1])
      when "bit_or"
        raise "bit_or float" if gtype.type_def.is_floating_point_numeric?
        @builder.or(params[0], params[1])
      when "bit_xor"
        raise "bit_xor float" if gtype.type_def.is_floating_point_numeric?
        @builder.xor(params[0], params[1])
      when "bit_shl"
        raise "bit_shl float" if gtype.type_def.is_floating_point_numeric?
        bits = @builder.zext(params[1], llvm_type_of(gtype))
        clamp = llvm_type_of(gtype).const_int(bit_width_of(gtype) - 1)
        bits = @builder.select(
          @builder.icmp(LLVM::IntPredicate::ULE, bits, clamp),
          bits,
          clamp,
        )
        @builder.shl(params[0], bits)
      when "bit_shr"
        raise "bit_shr float" if gtype.type_def.is_floating_point_numeric?
        bits = @builder.zext(params[1], llvm_type_of(gtype))
        clamp = llvm_type_of(gtype).const_int(bit_width_of(gtype) - 1)
        bits = @builder.select(
          @builder.icmp(LLVM::IntPredicate::ULE, bits, clamp),
          bits,
          clamp,
        )
        if gtype.type_def.is_signed_numeric?
          @builder.ashr(params[0], bits)
        else
          @builder.lshr(params[0], bits)
        end
      when "invert"
        raise "invert float" if gtype.type_def.is_floating_point_numeric?
        @builder.not(params[0])
      when "reverse_bits"
        raise "reverse_bits float" if gtype.type_def.is_floating_point_numeric?
        op_func =
          case bit_width_of(gtype)
          when 1
            @mod.functions["llvm.bitreverse.i1"]? ||
              @mod.functions.add("llvm.bitreverse.i1", [@i1], @i1)
          when 8
            @mod.functions["llvm.bitreverse.i8"]? ||
              @mod.functions.add("llvm.bitreverse.i8", [@i8], @i8)
          when 16
            @mod.functions["llvm.bitreverse.i16"]? ||
              @mod.functions.add("llvm.bitreverse.i16", [@i16], @i16)
          when 32
            @mod.functions["llvm.bitreverse.i32"]? ||
              @mod.functions.add("llvm.bitreverse.i32", [@i32], @i32)
          when 64
            @mod.functions["llvm.bitreverse.i64"]? ||
              @mod.functions.add("llvm.bitreverse.i64", [@i64], @i64)
          else raise NotImplementedError.new(bit_width_of(gtype))
          end
        @builder.call(op_func, [params[0]])
      when "swap_bytes"
        raise "swap_bytes float" if gtype.type_def.is_floating_point_numeric?
        case bit_width_of(gtype)
        when 1, 8
          params[0]
        when 32
          op_func =
            @mod.functions["llvm.bswap.i32"]? ||
              @mod.functions.add("llvm.bswap.i32", [@i32], @i32)
          @builder.call(op_func, [params[0]])
        when 64
          op_func =
            @mod.functions["llvm.bswap.i64"]? ||
              @mod.functions.add("llvm.bswap.i64", [@i64], @i64)
          @builder.call(op_func, [params[0]])
        else raise NotImplementedError.new(bit_width_of(gtype))
        end
      when "leading_zeros"
        raise "leading_zeros float" if gtype.type_def.is_floating_point_numeric?
        op_func =
          case bit_width_of(gtype)
          when 1
            @mod.functions["llvm.ctlz.i1"]? ||
              @mod.functions.add("llvm.ctlz.i1", [@i1, @i1], @i1)
          when 8
            @mod.functions["llvm.ctlz.i8"]? ||
              @mod.functions.add("llvm.ctlz.i8", [@i8, @i1], @i8)
          when 32
            @mod.functions["llvm.ctlz.i32"]? ||
              @mod.functions.add("llvm.ctlz.i32", [@i32, @i1], @i32)
          when 16
            @mod.functions["llvm.ctlz.i16"]? ||
              @mod.functions.add("llvm.ctlz.i16", [@i16, @i1], @i16)
          when 64
            @mod.functions["llvm.ctlz.i64"]? ||
              @mod.functions.add("llvm.ctlz.i64", [@i64, @i1], @i64)
          else raise NotImplementedError.new(bit_width_of(gtype))
          end
        gen_numeric_conv gtype, @gtypes["U8"],
          @builder.call(op_func, [params[0], @i1_false])
      when "trailing_zeros"
        raise "trailing_zeros float" if gtype.type_def.is_floating_point_numeric?
        op_func =
          case bit_width_of(gtype)
          when 1
            @mod.functions["llvm.cttz.i1"]? ||
              @mod.functions.add("llvm.cttz.i1", [@i1, @i1], @i1)
          when 8
            @mod.functions["llvm.cttz.i8"]? ||
              @mod.functions.add("llvm.cttz.i8", [@i8, @i1], @i8)
          when 16
            @mod.functions["llvm.cttz.i16"]? ||
              @mod.functions.add("llvm.cttz.i16", [@i16, @i1], @i16)
          when 32
            @mod.functions["llvm.cttz.i32"]? ||
              @mod.functions.add("llvm.cttz.i32", [@i32, @i1], @i32)
          when 64
            @mod.functions["llvm.cttz.i64"]? ||
              @mod.functions.add("llvm.cttz.i64", [@i64, @i1], @i64)
          else raise NotImplementedError.new(bit_width_of(gtype))
          end
        gen_numeric_conv gtype, @gtypes["U8"],
          @builder.call(op_func, [params[0], @i1_false])
      when "count_ones"
        raise "count_ones float" if gtype.type_def.is_floating_point_numeric?
        op_func =
          case bit_width_of(gtype)
          when 1
            @mod.functions["llvm.ctpop.i1"]? ||
              @mod.functions.add("llvm.ctpop.i1", [@i1], @i1)
          when 8
            @mod.functions["llvm.ctpop.i8"]? ||
              @mod.functions.add("llvm.ctpop.i8", [@i8], @i8)
          when 16
            @mod.functions["llvm.ctpop.i16"]? ||
              @mod.functions.add("llvm.ctpop.i16", [@i16], @i16)
          when 32
            @mod.functions["llvm.ctpop.i32"]? ||
              @mod.functions.add("llvm.ctpop.i32", [@i32], @i32)
          when 64
            @mod.functions["llvm.ctpop.i64"]? ||
              @mod.functions.add("llvm.ctpop.i64", [@i64], @i64)
          else raise NotImplementedError.new(bit_width_of(gtype))
          end
        gen_numeric_conv gtype, @gtypes["U8"], \
          @builder.call(op_func, [params[0]])
      when "bits"
        raise "bits integer" unless gtype.type_def.is_floating_point_numeric?
        case bit_width_of(gtype)
        when 32 then @builder.bit_cast(params[0], @i32)
        when 64 then @builder.bit_cast(params[0], @i64)
        else raise NotImplementedError.new(bit_width_of(gtype))
        end
      when "from_bits"
        raise "from_bits integer" unless gtype.type_def.is_floating_point_numeric?
        case bit_width_of(gtype)
        when 32 then @builder.bit_cast(params[0], @f32)
        when 64 then @builder.bit_cast(params[0], @f64)
        else raise NotImplementedError.new(bit_width_of(gtype))
        end
      when "next_pow2"
        raise "next_pow2 float" if gtype.type_def.is_floating_point_numeric?
        
        arg =
          if bit_width_of(gtype) > bit_width_of(@isize)
            @builder.trunc(params[0], @isize)
          else
            @builder.zext(params[0], @isize)
          end
        res = @builder.call(@mod.functions["ponyint_next_pow2"], [arg])
        
        if bit_width_of(gtype) < bit_width_of(@isize)
          @builder.trunc(res, llvm_type_of(gtype))
        else
          @builder.zext(res, llvm_type_of(gtype))
        end
      else
        raise NotImplementedError.new(gfunc.func.ident.inspect)
      end
    
    gen_func_end
  end
  
  def resolve_call(relate : AST::Relate, in_gfunc : GenFunc? = nil)
    member_ast, args_ast, yield_params_ast, yield_block_ast = AST::Extract.call(relate)
    lhs_type = type_of(relate.lhs, in_gfunc)
    member = member_ast.value
    
    # Even if there are multiple possible gtypes and thus gfuncs, we choose an
    # arbitrary one for the purposes of checking arg types against param types.
    # We make the assumption that signature differences have been prevented.
    lhs_gtype = @gtypes[ctx.reach[lhs_type.any_callable_defn_for(member)].llvm_name] # TODO: simplify this mess of an expression
    gfunc = lhs_gtype[member]
    
    {lhs_gtype, gfunc}
  end
  
  def gen_dot(relate)
    member_ast, args_ast, yield_params_ast, yield_block_ast = AST::Extract.call(relate)
    
    member = member_ast.value
    arg_exprs = args_ast.try(&.terms.dup) || [] of AST::Node
    args = arg_exprs.map { |x| gen_expr(x).as(LLVM::Value) }
    
    lhs_type = type_of(relate.lhs)
    lhs_gtype, gfunc = resolve_call(relate)
    
    # For any args we are missing, try to find and use a default param value.
    gfunc.func.params.try do |params|
      while args.size < params.terms.size
        param = params.terms[args.size]
        
        param_default = AST::Extract.param(param)[2]
        
        raise "missing arg #{args.size + 1} with no default param:"\
          "\n#{relate.pos.show}" unless param_default
        
        # Somewhat hacky unwrapping to aid the source_code_position_of_argument check below.
        param_default = param_default.terms.first \
          if param_default.is_a?(AST::Group) && param_default.terms.size == 1
        
        arg_exprs << param_default
        
        if param_default.is_a?(AST::Prefix) \
        && param_default.op.value == "source_code_position_of_argument"
          # If this is supposed to be a literal representing the source code of
          # an argument, we first must find the index of the argument specified.
          foreign_refer = gen_within_foreign_frame(lhs_gtype, gfunc) { func_frame.refer }
          find_ref = foreign_refer[param_default.term]
          found_index = \
            params.terms.index { |o| foreign_refer[AST::Extract.param(o)[0]] == find_ref }
          
          # Now, generate a value representing the source code pos of that arg.
          args << gen_source_code_pos(arg_exprs[found_index.not_nil!].pos)
        else
          gen_within_foreign_frame lhs_gtype, gfunc do
            args << gen_expr(param_default)
          end
        end
      end
    end
    
    # Generate code for the receiver, whether we actually use it or not.
    # We trust LLVM optimizations to eliminate dead code when it does nothing.
    receiver = gen_expr(relate.lhs)
    
    # Determine if we need to use a virtual call here.
    needs_virtual_call = lhs_type.is_abstract?
    
    # If this is a constructor, the receiver must be allocated first.
    if gfunc.func.has_tag?(:constructor)
      raise "can't do a virtual call on a constructor" if needs_virtual_call
      receiver = gen_alloc(lhs_gtype, "#{lhs_gtype.type_def.llvm_name}.new")
    end
    
    # Prepend the receiver to the args list if necessary.
    if gfunc.needs_receiver? || needs_virtual_call || gfunc.needs_send?
      args.unshift(receiver)
      arg_exprs.unshift(relate.lhs)
    end
    
    # Call the LLVM function, or do a virtual call if necessary.
    @di.set_loc(relate.op)
    result =
      if needs_virtual_call
        gen_virtual_call(receiver, args, arg_exprs, lhs_type, gfunc)
      elsif gfunc.needs_send?
        gen_call(gfunc.send_llvm_func, args, arg_exprs)
      else
        gen_call(gfunc.llvm_func, args, arg_exprs)
      end
    
    case gfunc.calling_convention
    when :simple_cc
      # Do nothing - we already have the result value we need.
    when :constructor_cc
      # The result is the receiver we sent over as an argument.
      result = receiver if gfunc.func.has_tag?(:constructor)
    when :error_cc
      # If this is an error-able function, check the error bit in the tuple.
      error_bit = @builder.extract_value(result, 1)
      
      error_block = gen_block("error_return")
      after_block = gen_block("after_return")
      
      is_error = @builder.icmp(LLVM::IntPredicate::EQ, error_bit, @i1_true)
      @builder.cond(is_error, error_block, after_block)
      
      @builder.position_at_end(error_block)
      # TODO: Should we try to avoid destructuring and restructuring the
      # tuple value here? Or does LLVM optimize it away so as to not matter?
      gen_raise_error(@builder.extract_value(result, 0))
      
      @builder.position_at_end(after_block)
      result = @builder.extract_value(result, 0)
    when :yield_cc
      raise NotImplementedError.new "continuation type for virtual call" \
        if needs_virtual_call
      
      # Since a yield block is kind of like a loop, we need an alloca to cover
      # the "variable" that changes each iteration - the last call result.
      result_alloca =
        if func_frame.gfunc.not_nil!.calling_convention == :yield_cc
          func_frame.gfunc.not_nil!.continuation_info
            .struct_gep_for_yielded_result(func_frame, relate)
        else
          gen_alloca(result.type, "RESULT.YIELDED.OPAQUE.ALLOCA")
        end
      @builder.store(result, result_alloca)
      
      # We declare the alloca itself, as well as bit casted aliases.
      # Declare some code blocks in which we'll generate this pseudo-loop.
      maybe_block = gen_block("maybe_yield_block")
      yield_block = gen_block("yield_block")
      after_block = gen_block("after_call")
      
      # We start at the "maybe block" right after the first call above.
      # We'll also return here after subsequent continue calls below.
      # The "maybe block" makes the determination of whether or not to jump to
      # the yield block, based on the function pointer in the continuation.
      # If the function pointer is NULL, then that means there is no more
      # continuing to be done, and therefore the yield block shouldn't be run.
      # If the function pointer is non-NULL, we go to the yield block.
      @builder.br(maybe_block)
      @builder.position_at_end(maybe_block)
      yield_result_alloca = @builder.bit_cast(result_alloca,
        gfunc.yield_cc_yield_return_type.pointer, "RESULT.YIELDED.ALLOCA")
      yield_result = @builder.load(yield_result_alloca, "RESULT.YIELDED")
      cont = @builder.extract_value(yield_result, 0, "CONT")
      is_finished = gfunc.continuation_info.check_next_func_is_null(cont)
      @builder.cond(is_finished, after_block, yield_block)
      
      # Move our cursor to the yield block to start generating code there.
      @builder.position_at_end(yield_block)
      
      # If the yield block uses yield params, we treat them as locals,
      # which means they need a gep to be able to load them later.
      # We get the values from the earlier stored yield_out_allocas.
      if yield_params_ast
        yield_params_ast.terms.each_with_index do |yield_param_ast, index|
          @di.set_loc(yield_param_ast)
          
          yield_param_ref = func_frame.refer[yield_param_ast]
          yield_param_ref = yield_param_ref.as(Refer::Local)
          yield_param_gep = func_frame.current_locals[yield_param_ref] ||=
            gen_local_gep(yield_param_ref, llvm_type_of(yield_param_ast))
          
          yield_out = @builder.extract_value(yield_result, index + 1, yield_param_ref.name)
          yield_out = @builder.bit_cast(yield_out, llvm_type_of(yield_param_ast))
          @builder.store(yield_out, yield_param_gep)
        end
      end
      
      # Now we generate the actual code for the yield block.
      yield_in_value = gen_expr(yield_block_ast.not_nil!)
      
      # If None is the yield in value type expected, just generate None,
      # allowing us to ignore the actual result value of the yield block.
      yield_in_type = gfunc.continuation_llvm_func_ptr.element_type.params_types[1]
      if yield_in_type == @gtypes["None"].struct_type.pointer
        yield_in_value = gen_none
      end
      
      # After the yield block, we call the continue function pointer,
      # which we extracted from continuation data earlier in the "maybe block",
      # but must now extract again here, since we can't be sure that the other
      # block actually preceded/dominates this one in all possible permutations.
      # We pass the receiver, continuation data, and yield_in_value back as
      # the arguments to the continue call, as the function signature expects.
      yield_result_alloca = @builder.bit_cast(result_alloca,
        gfunc.yield_cc_yield_return_type.pointer, "RESULT.YIELDED.ALLOCA")
      yield_result = @builder.load(yield_result_alloca, "RESULT.YIELDED")
      cont = @builder.extract_value(yield_result, 0, "CONT")
      next_func = gfunc.continuation_info.get_next_func(cont)
      again_args = [cont, yield_in_value]
      @di.set_loc(relate.op)
      again_result = @builder.call(next_func, again_args)
      @builder.store(again_result, result_alloca)
      
      # Return to the "maybe block", to determine if we need to iterate again.
      @builder.br(maybe_block)
      
      # Finally, finish with the "real" result of the call.
      @builder.position_at_end(after_block)
      final_result_alloca = @builder.bit_cast(result_alloca,
        gfunc.yield_cc_final_return_type.pointer, "RESULT.ALLOCA")
      final_result_return = @builder.load(
        @builder.struct_gep(final_result_alloca, 1, "RESULT.RETURN.GEP"),
        "RESULT.RETURN",
      )
      result = final_result_return
    else
      raise NotImplementedError.new(gfunc.calling_convention)
    end
    
    result
  end
  
  def gen_virtual_call(
    receiver : LLVM::Value,
    args : Array(LLVM::Value),
    arg_exprs : Array(AST::Node),
    type_ref : Reach::Ref,
    gfunc : GenFunc,
  )
    receiver.name = type_ref.show_type if receiver.name.empty?
    rname = receiver.name
    fname = "#{rname}.#{gfunc.func.ident.value}"
    
    # Load the type descriptor of the receiver so we can read its vtable,
    # then load the function pointer from the appropriate index of that vtable.
    desc = gen_get_desc(receiver)
    vtable_gep = @builder.struct_gep(desc, DESC_VTABLE, "#{rname}.DESC.VTABLE")
    vtable_idx = @i32.const_int(gfunc.vtable_index)
    gep = @builder.inbounds_gep(vtable_gep, @i32_0, vtable_idx, "#{fname}.GEP")
    load = @builder.load(gep, "#{fname}.LOAD")
    func = @builder.bit_cast(load, gfunc.virtual_llvm_func.type, fname)
    
    gen_call(func, gfunc.virtual_llvm_func, args, arg_exprs)
  end
  
  def gen_call(
    func : LLVM::Function,
    args : Array(LLVM::Value),
    arg_exprs : Array(AST::Node),
  )
    # Cast the arguments to the right types.
    cast_args = func.params.to_a.zip(args).zip(arg_exprs)
      .map { |(param, arg), expr| gen_assign_cast(arg, param.type, expr) }
    
    @builder.call(func, cast_args)
  end
  
  def gen_call(
    func : LLVM::Value,
    func_proto : LLVM::Function,
    args : Array(LLVM::Value),
    arg_exprs : Array(AST::Node),
  )
    # This version of gen_call uses a separate func_proto as the prototype,
    # which we use to get the parameter types to cast the arguments to.
    cast_args = func_proto.params.to_a.zip(args).zip(arg_exprs)
      .map { |(param, arg), expr| gen_assign_cast(arg, param.type, expr) }
    
    @builder.call(func, cast_args)
  end
  
  def gen_eq(relate)
    ref = func_frame.refer[relate.lhs]
    value = gen_expr(relate.rhs).as(LLVM::Value)
    name = value.name
    lhs_type = llvm_type_of(relate.lhs)
    
    cast_value = gen_assign_cast(value, lhs_type, relate.rhs)
    cast_value.name = value.name
    
    @di.set_loc(relate.op)
    if ref.is_a?(Refer::Local)
      gep = func_frame.current_locals[ref] ||= gen_local_gep(ref, lhs_type)
      
      @builder.store(cast_value, gep)
    else
      raise NotImplementedError.new(relate.inspect)
    end
    
    cast_value
  end
  
  def gen_field_eq(node : AST::FieldWrite)
    value = gen_expr(node.rhs).as(LLVM::Value)
    name = value.name
    
    value = gen_assign_cast(value, llvm_type_of(node), node.rhs)
    value.name = name
    
    @di.set_loc(node)
    gen_field_store(node.value, value)
    value
  end
  
  def gen_check_identity_is(relate : AST::Relate)
    lhs_type = type_of(relate.lhs)
    rhs_type = type_of(relate.rhs)
    lhs = gen_expr(relate.lhs)
    rhs = gen_expr(relate.rhs)
    
    if lhs.type.kind == LLVM::Type::Kind::Integer \
    && rhs.type.kind == LLVM::Type::Kind::Integer
      if lhs.type == rhs.type
        # Integers of the same type are compared by integer comparison.
        @builder.icmp(
          LLVM::IntPredicate::EQ,
          lhs,
          rhs,
          "#{lhs.name}.is.#{rhs.name}",
        )
      else
        # Integers of different types never have the same identity.
        gen_bool(false)
      end
    elsif lhs_type == rhs_type \
    && lhs.type.kind == LLVM::Type::Kind::Pointer \
    && rhs.type.kind == LLVM::Type::Kind::Pointer \
    && lhs.type == llvm_type_of(lhs_type) \
    && rhs.type == llvm_type_of(rhs_type)
      # Objects (not boxed machine words) of the same type are compared by
      # integer comparison of the pointer to the object.
      @builder.icmp(
        LLVM::IntPredicate::EQ,
        @builder.bit_cast(lhs, @obj_ptr, "#{lhs.name}.CAST"),
        @builder.bit_cast(rhs, @obj_ptr, "#{rhs.name}.CAST"),
        "#{lhs.name}.is.#{rhs.name}",
      )
    else
      raise NotImplementedError.new("this comparison:\n#{relate.pos.show}")
    end
  end
  
  def gen_identity_digest_of(term_expr)
    term_type = type_of(term_expr)
    value = gen_expr(term_expr)
    name = "identity_digest_of.#{value.name}"
    
    case value.type.kind
    when LLVM::Type::Kind::Float
      @builder.zext(@builder.bit_cast(value, @i32), @isize, name)
    when LLVM::Type::Kind::Double
      gen_identity_digest_of_i64(@builder.bit_cast(value, @i64), name)
    when LLVM::Type::Kind::Integer
      case value.type.int_width
      when @bitwidth
        value
      when 64
        gen_identity_digest_of_i64(value, name)
      else
        @builder.zext(value, @isize, name)
      end
    when LLVM::Type::Kind::Pointer
      if llvm_type_of(term_type).kind == LLVM::Type::Kind::Pointer
        @builder.ptr_to_int(value, @isize, name)
      else
        # When the value is a pointer, but the type is not, the value is boxed.
        # Therefore, we must unwrap the boxed value and get its digest.
        # TODO: Implement this.
        raise NotImplementedError.new("unboxing digest:\n#{term_expr.pos.show}")
      end
    else
      raise NotImplementedError.new("this digest:\n#{term_expr.pos.show}")
    end
  end
  
  def gen_identity_digest_of_i64(value : LLVM::Value, name : String)
    raise "not i64" unless value.type == @i64
    
    case @bitwidth
    when 64
      value.name = name
      value
    when 32
      # On 32-bit platforms, the digest of an i64 only has 32 bits,
      # so we need to XOR the high and low halves together into one i32.
      @builder.xor(
        @builder.trunc(@builder.lshr(value, @i64.const_int(32)), @i32),
        @builder.trunc(value, @i32),
        name
      )
    else
      raise NotImplementedError.new(@bitwidth)
    end
  end
  
  def gen_check_subtype(relate : AST::Relate)
    infer = func_frame.gfunc.not_nil!.infer
    
    if infer[relate.lhs].is_a?(Infer::Fixed)
      # If the left-hand side is a fixed compile-time type (and knowing that
      # the right-hand side always is), we can return a compile-time true/false.
      lhs_meta_type = infer.resolve(relate.lhs)
      rhs_meta_type = infer.resolve(relate.rhs)
      
      gen_bool(lhs_meta_type.satisfies_bound?(infer, rhs_meta_type))
    else
      # Otherwise, we generate code that checks the type descriptor of the
      # left-hand side against the compile-time type of the right-hand side.
      gen_check_subtype_at_runtime(gen_expr(relate.lhs), type_of(relate.rhs))
    end
  end
  
  def gen_check_subtype_at_runtime(lhs : LLVM::Value, rhs_type : Reach::Ref)
    if rhs_type.is_concrete?
      rhs_gtype = @gtypes[ctx.reach[rhs_type.single!].llvm_name]
      
      lhs_desc = gen_get_desc_opaque(lhs)
      rhs_desc = gen_get_desc_opaque(rhs_gtype)
      
      @builder.icmp LLVM::IntPredicate::EQ, lhs_desc, rhs_desc, "#{lhs.name}<:"
    else
      type_def = rhs_type.single_def!(ctx)
      rhs_name = type_def.llvm_name
      trait_id = @isize.const_int(type_def.desc_id)
      
      # Based on the trait id, determine the values to use for bitmap testing.
      shift = @llvm.const_lshr(
        trait_id,
        @isize.const_int(Math.log2(@bitwidth).to_i),
      )
      mask = @llvm.const_shl(
        @isize.const_int(1),
        @llvm.const_and(trait_id, @isize.const_int(@bitwidth - 1)),
      )
      
      # Load the trait bitmap of the concrete type descriptor of the lhs.
      desc = gen_get_desc(lhs)
      traits_gep = @builder.struct_gep(desc, DESC_TRAITS, "#{lhs.name}.DESC.TRAITS.GEP")
      traits = @builder.load(traits_gep, "#{lhs.name}.DESC.TRAITS")
      bits_gep = @builder.inbounds_gep(traits, @i32_0, shift, "#{lhs.name}.DESC.TRAITS.GEP.#{rhs_name}")
      bits = @builder.load(bits_gep, "#{lhs.name}.DESC.TRAITS.#{rhs_name}")
      
      # If the bit for this trait is present, then it's a runtime type match.
      @builder.icmp(
        LLVM::IntPredicate::NE,
        @builder.and(bits, mask, "#{lhs.name}<:#{rhs_name}.BITS"),
        @isize.const_int(0),
        "#{lhs.name}<:#{rhs_name}"
      )
    end
  end
  
  def gen_assign_cast(
    value : LLVM::Value,
    to_type : LLVM::Type,
    from_expr : AST::Node?,
  )
    from_type = value.type
    return value if from_type == to_type
    
    case to_type.kind
    when LLVM::Type::Kind::Integer,
         LLVM::Type::Kind::Half,
         LLVM::Type::Kind::Float,
         LLVM::Type::Kind::Double
      # This happens for example with Bool when llvm_use_type != llvm_mem_type,
      # for cases where we are assigning to or from a field.
      # TODO: Implement this and verify it is working as intended.
      raise NotImplementedError.new("zero extension / truncation in cast") \
        if from_type.kind == LLVM::Type::Kind::Integer \
        && to_type.kind == LLVM::Type::Kind::Integer \
        && to_type.int_width != from_type.int_width
      
      # This is just an assertion to make sure the type system protected us
      # from trying to implicitly cast between different numeric types.
      # We should only be going to/from a boxed pointer container.
      raise "can't cast to/from different numeric types implicitly" \
        if from_type.kind != LLVM::Type::Kind::Pointer
      
      # Unwrap the box and finish the assign cast from there.
      # This brings us to the zero extension / truncation logic above.
      value = gen_unboxed(value, gtype_of(from_expr.not_nil!))
      gen_assign_cast(value, to_type, from_expr)
    when LLVM::Type::Kind::Pointer
      from_expr_type = type_of(from_expr.not_nil!)
      if value.type.kind != LLVM::Type::Kind::Pointer
        # If we're going from non-pointer to pointer, we're boxing.
        value = gen_boxed(value, gtype_of(from_expr_type))
      elsif from_expr_type.singular? && from_expr_type.single_def!(ctx).is_cpointer?
        if value.type != @obj_ptr && to_type == @obj_ptr
          # If going from non-object cpointer to object pointer, we're boxing.
          value = gen_boxed(value, gtype_of(from_expr_type))
        elsif value.type == @obj_ptr && to_type != @obj_ptr
          # If going from object pointer to non-object cpointer, we're unboxing.
          value = gen_unboxed(value, gtype_of(from_expr_type))
        end
      end
      
      # Do the LLVM bitcast.
      @builder.bit_cast(value, to_type, "#{value.name}.CAST")
    else
      raise NotImplementedError.new(to_type.kind)
    end
  end
  
  def gen_boxed(value, from_gtype)
    # Allocate a struct pointer to hold the type descriptor and value.
    # This also writes the type descriptor into it appropriate position.
    boxed = gen_alloc(from_gtype, "#{value.name}.BOXED")
    
    # Write the value itself into the value field of the struct.
    value_gep = @builder.struct_gep(boxed, 1, "#{value.name}.BOXED.VALUE")
    @builder.store(value, value_gep)
    
    # Return the struct pointer
    boxed
  end
  
  def gen_unboxed(value, from_gtype)
    # First, cast the given object pointer to the correct boxed struct pointer.
    struct_ptr = from_gtype.struct_ptr
    value = @builder.bit_cast(value, struct_ptr, "#{value.name}.BOXED")
    
    # Load the value itself into the value field of the boxed struct pointer.
    value_gep = @builder.struct_gep(value, 1, "#{value.name}.VALUE")
    @builder.load(value_gep, "#{value.name}.VALUE.LOAD")
  end
  
  def gen_expr(expr, const_only = false) : LLVM::Value
    @di.set_loc(expr)
    
    case expr
    when AST::Identifier
      ref = func_frame.refer[expr]
      if ref.is_a?(Refer::Local)
        raise "#{ref.inspect} isn't a constant value" if const_only
        alloca = func_frame.current_locals[ref]
        @builder.load(alloca, ref.name)
      elsif ref.is_a?(Refer::Type) || ref.is_a?(Refer::TypeAlias)
        enum_value = ref.metadata[:enum_value]?
        if enum_value
          llvm_type_of(expr).const_int(enum_value.as(Int32))
        elsif ref.defn.has_tag?(:numeric)
          llvm_type = llvm_type_of(expr)
          case llvm_type.kind
          when LLVM::Type::Kind::Integer then llvm_type.const_int(0)
          when LLVM::Type::Kind::Float then llvm_type.const_float(0)
          when LLVM::Type::Kind::Double then llvm_type.const_double(0)
          else raise NotImplementedError.new(llvm_type)
          end
        else
          gtype_of(expr).singleton
        end
      elsif ref.is_a?(Refer::TypeParam)
        # TODO: unify with above clause
        defn = gtype_of(expr).type_def.program_type
        enum_value = defn.metadata[:enum_value]?
        if enum_value
          llvm_type_of(expr).const_int(enum_value.as(UInt64).to_i32)
        elsif defn.has_tag?(:numeric)
          llvm_type = llvm_type_of(expr)
          case llvm_type.kind
          when LLVM::Type::Kind::Integer then llvm_type.const_int(0)
          when LLVM::Type::Kind::Float then llvm_type.const_float(0)
          when LLVM::Type::Kind::Double then llvm_type.const_double(0)
          else raise NotImplementedError.new(llvm_type)
          end
        else
          gtype_of(expr).singleton
        end
      elsif ref.is_a?(Refer::Self)
        raise "#{ref.inspect} isn't a constant value" if const_only
        func_frame.receiver_value
      elsif ref.is_a?(Refer::RaiseError)
        gen_raise_error
      else
        raise NotImplementedError.new("#{ref}\n#{expr.pos.show}")
      end
    when AST::FieldRead
      gen_field_load(expr.value)
    when AST::FieldWrite
      gen_field_eq(expr)
    when AST::LiteralString
      gen_string(expr.value)
    when AST::LiteralCharacter
      gen_integer(expr)
    when AST::LiteralInteger
      gen_integer(expr)
    when AST::LiteralFloat
      gen_float(expr)
    when AST::Relate
      raise "#{expr.inspect} isn't a constant value" if const_only
      case expr.op.as(AST::Operator).value
      when "." then gen_dot(expr)
      when "=" then gen_eq(expr)
      when "is" then gen_check_identity_is(expr)
      when "<:" then gen_check_subtype(expr)
      else raise NotImplementedError.new(expr.inspect)
      end
    when AST::Group
      raise "#{expr.inspect} isn't a constant value" if const_only
      case expr.style
      when "(", ":" then gen_sequence(expr)
      when "["      then gen_dynamic_array(expr)
      else raise NotImplementedError.new(expr.inspect)
      end
    when AST::Choice
      raise "#{expr.inspect} isn't a constant value" if const_only
      gen_choice(expr)
    when AST::Loop
      raise "#{expr.inspect} isn't a constant value" if const_only
      gen_loop(expr)
    when AST::Try
      raise "#{expr.inspect} isn't a constant value" if const_only
      gen_try(expr)
    when AST::Yield
      raise "#{expr.inspect} isn't a constant value" if const_only
      gen_yield(expr)
    when AST::Prefix
      case expr.op.value
      when "reflection_of_type"
        gen_reflection_of_type(expr, expr.term)
      when "identity_digest_of"
        gen_identity_digest_of(expr.term)
      when "--"
        gen_expr(expr.term, const_only)
      else
        raise NotImplementedError.new(expr.inspect)
      end
    when AST::Qualify
      gtype_of(expr).singleton
    else
      raise NotImplementedError.new(expr.inspect)
    end
  end
  
  def gen_none
    @gtypes["None"].singleton
  end
  
  def gen_bool(bool)
    @i1.const_int(bool ? 1 : 0)
  end
  
  def gen_integer(expr : (AST::LiteralInteger | AST::LiteralCharacter))
    type_ref = type_of(expr)
    case type_ref.llvm_use_type
    when :i1 then @i1.const_int(expr.value.to_i8)
    when :i8 then @i8.const_int(expr.value.to_i8)
    when :i16 then @i16.const_int(expr.value.to_i16)
    when :i32 then @i32.const_int(expr.value.to_i32)
    when :i64 then @i64.const_int(expr.value.to_i64)
    when :f32 then @f32.const_float(expr.value.to_f32)
    when :f64 then @f64.const_double(expr.value.to_f64)
    when :isize then @isize.const_int(
      (abi_size_of(@isize) == 8) \
      ? expr.value.to_i64
      : expr.value.to_i32
    )
    else raise "invalid numeric literal type: #{type_ref.inspect}"
    end
  end
  
  def gen_float(expr : AST::LiteralFloat)
    type_ref = type_of(expr)
    case type_ref.llvm_use_type
    when :f32 then @f32.const_float(expr.value.to_f32)
    when :f64 then @f64.const_double(expr.value.to_f64)
    else raise "invalid floating point literal type: #{type_ref.inspect}"
    end
  end
  
  def gen_as_cond(value : LLVM::Value)
    case value.type
    when @i1 then value
    when @obj_ptr
      # When an object pointer, assume that it is a boxed Bool object,
      # meaning that we need to unbox it as such here. This will fail
      # in a silent and ugly way if the type system doesn't properly
      # ensure that the value we hold here is truly a Bool.
      @builder.load(
        @builder.struct_gep(
          @builder.bit_cast(
            value,
            @gtypes["Bool"].struct_ptr,
            "#{value.name}.BOXED",
          ),
          1,
          "#{value.name}.VALUE",
        ),
        "#{value.name}.VALUE.LOAD",
      )
    else
      raise NotImplementedError.new(value.type)
    end
  end
  
  def bit_width_of(gtype : GenType)
    bit_width_of(llvm_type_of(gtype))
  end
  
  def bit_width_of(llvm_type : LLVM::Type)
    abi_size_of(llvm_type) * 8
  end
  
  def gen_numeric_conv(
    from_gtype : GenType,
    to_gtype : GenType,
    value : LLVM::Value,
  )
    from_signed = from_gtype.type_def.is_signed_numeric?
    to_signed = to_gtype.type_def.is_signed_numeric?
    from_float = from_gtype.type_def.is_floating_point_numeric?
    to_float = to_gtype.type_def.is_floating_point_numeric?
    from_width = bit_width_of(from_gtype)
    to_width = bit_width_of(to_gtype)
    
    to_llvm_type = llvm_type_of(to_gtype)
    
    if from_float && to_float
      if from_width < to_width
        @builder.fpext(value, to_llvm_type)
      elsif from_width > to_width
        raise "unexpected from_width: #{from_width}" unless from_width == 64
        raise "unexpected to_width: #{to_width}" unless to_width == 32
        gen_numeric_conv_f64_to_f32(value)
      else
        value
      end
    elsif from_float && to_signed
      case from_width
      when 32 then gen_numeric_conv_f32_to_sint(value, to_llvm_type)
      when 64 then gen_numeric_conv_f64_to_sint(value, to_llvm_type)
      else raise NotImplementedError.new(from_width)
      end
    elsif from_float
      case from_width
      when 32 then gen_numeric_conv_f32_to_uint(value, to_llvm_type)
      when 64 then gen_numeric_conv_f64_to_uint(value, to_llvm_type)
      else raise NotImplementedError.new(from_width)
      end
    elsif from_signed && to_float
      @builder.si2fp(value, to_llvm_type)
    elsif to_float
      @builder.ui2fp(value, to_llvm_type)
    elsif from_width > to_width
      @builder.trunc(value, to_llvm_type)
    elsif from_width < to_width
      if from_signed
        @builder.sext(value, to_llvm_type)
      else
        @builder.zext(value, to_llvm_type)
      end
    else
      value
    end
  end
  
  def gen_numeric_conv_float_handle_nan(
    value : LLVM::Value,
    int_type : LLVM::Type,
    exp : UInt64,
    mantissa : UInt64,
  )
    nan = gen_block("nan")
    non_nan = gen_block("non_nan")
    
    exp_mask = int_type.const_int(exp)
    mant_mask = int_type.const_int(mantissa)
    
    bits = @builder.bit_cast(value, int_type, "bits")
    exp_res = @builder.and(bits, exp_mask, "exp_res")
    mant_res = @builder.and(bits, mant_mask, "mant_res")
    
    exp_res = @builder.icmp(
      LLVM::IntPredicate::EQ, exp_res, exp_mask, "exp_res")
    mant_res = @builder.icmp(
      LLVM::IntPredicate::NE, mant_res, int_type.const_int(0), "mant_res")
    
    is_nan = @builder.and(exp_res, mant_res, "is_nan")
    @builder.cond(is_nan, nan, non_nan)
    @builder.position_at_end(nan)
    
    return non_nan
  end
  
  def gen_numeric_conv_float_handle_overflow_saturate(
    value : LLVM::Value,
    from_type : LLVM::Type,
    to_type : LLVM::Type,
    to_min : LLVM::Value,
    to_max : LLVM::Value,
    is_signed : Bool,
  )
    overflow = gen_block("overflow")
    test_underflow = gen_block("test_underflow")
    underflow = gen_block("underflow")
    normal = gen_block("normal")
    
    # Check if the floating-point value overflows the maximum integer value.
    to_fmax =
      if is_signed
        @builder.si2fp(to_max, from_type)
      else
        @builder.ui2fp(to_max, from_type)
      end
    is_overflow = @builder.fcmp(LLVM::RealPredicate::OGT, value, to_fmax)
    @builder.cond(is_overflow, overflow, test_underflow)
    
    # If it does overflow, return the maximum integer value.
    @builder.position_at_end(overflow)
    @builder.ret(to_max)
    
    # Check if the floating-point value underflows the minimum integer value.
    @builder.position_at_end(test_underflow)
    to_fmin =
      if is_signed
        @builder.si2fp(to_min, from_type)
      else
        @builder.ui2fp(to_min, from_type)
      end
    is_underflow = @builder.fcmp(LLVM::RealPredicate::OLT, value, to_fmin)
    @builder.cond(is_underflow, underflow, normal)
    
    # If it does underflow, return the minimum integer value.
    @builder.position_at_end(underflow)
    @builder.ret(to_min)
    
    # Otherwise, proceed with the conversion as normal.
    @builder.position_at_end(normal)
    if is_signed
      @builder.fp2si(value, to_type)
    else
      @builder.fp2ui(value, to_type)
    end
  end
  
  def gen_numeric_conv_f64_to_f32(value : LLVM::Value)
    # If the value is F64 NaN, return F32 NaN.
    test_overflow = gen_numeric_conv_float_handle_nan(
      value, @i64, 0x7FF0000000000000, 0x000FFFFFFFFFFFFF)
    @builder.ret(@llvm.const_bit_cast(@i32.const_int(0x7FC00000), @f32))
    
    overflow = gen_block("overflow")
    test_underflow = gen_block("test_underflow")
    underflow = gen_block("underflow")
    normal = gen_block("normal")
    
    # Check if the F64 value overflows the maximum F32 value.
    @builder.position_at_end(test_overflow)
    f32_max = @llvm.const_bit_cast(@i32.const_int(0x7F7FFFFF), @f32)
    f32_max = @builder.fpext(f32_max, @f64, "f32_max")
    is_overflow = @builder.fcmp(LLVM::RealPredicate::OGT, value, f32_max)
    @builder.cond(is_overflow, overflow, test_underflow)
    
    # If it does overflow, return positive infinity.
    @builder.position_at_end(overflow)
    @builder.ret(@llvm.const_bit_cast(@i32.const_int(0x7F800000), @f32))
    
    # Check if the F64 value underflows the minimum F32 value.
    @builder.position_at_end(test_underflow)
    f32_min = @llvm.const_bit_cast(@i32.const_int(0xFF7FFFFF), @f32)
    f32_min = @builder.fpext(f32_min, @f64, "f32_min")
    is_underflow = @builder.fcmp(LLVM::RealPredicate::OLT, value, f32_min)
    @builder.cond(is_underflow, underflow, normal)
    
    # If it does underflow, return negative infinity.
    @builder.position_at_end(underflow)
    @builder.ret(@llvm.const_bit_cast(@i32.const_int(0xFF800000), @f32))
    
    # Otherwise, proceed with the floating-point truncation as normal.
    @builder.position_at_end(normal)
    @builder.fptrunc(value, @f32)
  end
  
  def gen_numeric_conv_f32_to_sint(value : LLVM::Value, to_type : LLVM::Type)
    test_overflow = gen_numeric_conv_float_handle_nan(
      value, @i32, 0x7F800000, 0x007FFFFF)
    @builder.ret(to_type.const_int(0))
    
    @builder.position_at_end(test_overflow)
    to_min = @builder.not(to_type.const_int(0), "to_min.pre")
    to_max = @builder.lshr(to_min, to_type.const_int(1), "to_max")
    to_min = @builder.xor(to_max, to_min, "to_min")
    gen_numeric_conv_float_handle_overflow_saturate(
      value, @f32, to_type, to_min, to_max, true)
  end
  
  def gen_numeric_conv_f64_to_sint(value : LLVM::Value, to_type : LLVM::Type)
    test_overflow = gen_numeric_conv_float_handle_nan(
      value, @i64, 0x7FF0000000000000, 0x000FFFFFFFFFFFFF)
    @builder.ret(to_type.const_int(0))
    
    @builder.position_at_end(test_overflow)
    to_min = @builder.not(to_type.const_int(0), "to_min.pre")
    to_max = @builder.lshr(to_min, to_type.const_int(1), "to_max")
    to_min = @builder.xor(to_max, to_min, "to_min")
    gen_numeric_conv_float_handle_overflow_saturate(
      value, @f64, to_type, to_min, to_max, true)
  end
  
  def gen_numeric_conv_f32_to_uint(value : LLVM::Value, to_type : LLVM::Type)
    test_overflow = gen_numeric_conv_float_handle_nan(
      value, @i32, 0x7F800000, 0x007FFFFF)
    @builder.ret(to_type.const_int(0))
    
    @builder.position_at_end(test_overflow)
    to_min = to_type.const_int(0)
    to_max = @builder.not(to_min, "to_max")
    gen_numeric_conv_float_handle_overflow_saturate(
      value, @f32, to_type, to_min, to_max, false)
  end
  
  def gen_numeric_conv_f64_to_uint(value : LLVM::Value, to_type : LLVM::Type)
    test_overflow = gen_numeric_conv_float_handle_nan(
      value, @i64, 0x7FF0000000000000, 0x000FFFFFFFFFFFFF)
    @builder.ret(to_type.const_int(0))
    
    @builder.position_at_end(test_overflow)
    to_min = to_type.const_int(0)
    to_max = @builder.not(to_min, "to_max")
    gen_numeric_conv_float_handle_overflow_saturate(
      value, @f64, to_type, to_min, to_max, false)
  end
  
  def gen_global_for_const(const : LLVM::Value) : LLVM::Value
    global = @mod.globals.add(const.type, "")
    global.linkage = LLVM::Linkage::External # TODO: Private linkage?
    global.initializer = const
    global.global_constant = true
    global.unnamed_addr = true
    global
  end
  
  def gen_const_for_gtype(gtype : GenType, values : Hash(String, LLVM::Value))
    field_values = gtype.fields.map(&.first).map { |name| values[name] }
    
    gtype.struct_type.const_struct([gtype.desc] + field_values)
  end
  
  def gen_global_const(*args)
    gen_global_for_const(gen_const_for_gtype(*args))
  end
  
  def gen_cstring(value : String) : LLVM::Value
    @llvm.const_inbounds_gep(
      @cstring_globals.fetch value do
        global = gen_global_for_const(@llvm.const_string(value))
        
        @cstring_globals[value] = global
      end,
      [@i32_0, @i32_0],
    )
  end
  
  def gen_string(value : String)
    @string_globals.fetch value do
      global = gen_global_const(@gtypes["String"], {
        "_size"  => @isize.const_int(value.size),
        "_alloc" => @isize.const_int(value.size + 1),
        "_ptr"   => gen_cstring(value),
      })
      
      @string_globals[value] = global
    end
  end
  
  def gen_array(array_gtype, values : Array(LLVM::Value)) : LLVM::Value
    if values.size > 0
      values_type = values.first.type # assume all values have the same LLVM::Type
      values_global = gen_global_for_const(values_type.const_array(values))
      
      gen_global_const(array_gtype, {
        "_size"  => @isize.const_int(values.size),
        "_alloc" => @isize.const_int(values.size),
        "_ptr"   => @llvm.const_inbounds_gep(values_global, [@i32_0, @i32_0])
      })
    else
      gen_global_const(array_gtype, {
        "_size"  => @isize.const_int(0),
        "_alloc" => @isize.const_int(0),
        "_ptr"   => @ptr.null
      })
    end
  end
  
  def gen_source_code_pos(pos : Source::Pos)
    @source_code_pos_globals.fetch pos do
      global = gen_global_const(@gtypes["SourceCodePosition"], {
        "string"   => gen_string(pos.content),
        "filename" => gen_string(pos.source.filename),
        "row"      => @isize.const_int(pos.row),
        "col"      => @isize.const_int(pos.col),
      })
      
      @source_code_pos_globals[pos] = global
    end
  end
  
  def gen_reflection_of_type(expr, term_expr)
    reflect_gtype = gtype_of(expr)
    
    @reflection_of_type_globals.fetch reflect_gtype do
      reach_ref = type_of(term_expr)
      
      props = {} of String => LLVM::Value
      props["string"] = gen_string(reach_ref.show_type)
      
      if reflect_gtype.field?("features")
        features_gtype = gtype_of(reflect_gtype.field("features"))
        feature_gtype = gtype_of(
          features_gtype.field("_ptr")
            .single_def!(ctx).cpointer_type_arg
        )
        mutator_gtype = gtype_of(
          feature_gtype.field("mutator")
            .union_children.find(&.show_type.!=("None")).not_nil!
        )
        
        raise NotImplementedError.new(reach_ref.show_type) \
          unless reach_ref.singular?
        gtype = gtype_of(reach_ref)
        
        features =
          gtype.gfuncs.values
            .reject(&.func.has_tag?(:hygienic))
            .map do |gfunc|
              tags = gfunc.func.tags.map { |tag| gen_string(tag.to_s) }
              
              # A mutator must meet the following qualifications:
              # a ref function that takes no arguments and returns None.
              # Any other function can't be safely called this way, so we
              # leave its mutator field as None so that it can't be called.
              # In the future, we may make it possible to call other functions
              # that are not mutators, but that becomes a tough type system
              # problem to solve, not the least of which is type variable varargs.
              mutator =
                if gfunc.func.cap.value == "ref" \
                && (gfunc.func.params.try(&.terms.size) || 0) == 0 \
                && gfunc.llvm_func.return_type == @gtypes["None"].struct_type.pointer
                  gen_reflection_mutator_of_type(mutator_gtype, gtype, gfunc)
                else
                  gen_none
                end
              
              gen_global_const(feature_gtype, {
                "name" => gen_string(gfunc.func.ident.value),
                "tags" => gen_array(@gtypes["Array[String]"], tags),
                "mutator" => mutator,
              })
            end
        
        props["features"] = gen_array(features_gtype, features)
      end
      
      global = gen_global_const(reflect_gtype, props)
      
      @reflection_of_type_globals[reflect_gtype] = global
    end
  end
  
  def gen_reflection_mutator_of_type(mutator_gtype, gtype, gfunc)
    mutator_call_gfunc = mutator_gtype.gfuncs["call"]
    
    # This code is shamelessly copied from gen_desc, with a few modifications,
    # because we already know that we are just targeting exactly one gtype
    # (the mutator_gtype which this object is tailor-made to fit).
    traits_bitmap = trait_bitmap_size.times.map { 0 }.to_a
    mutator_gtype.type_def.tap do |other_def|
      raise "can't be subtype of a concrete" unless other_def.is_abstract?
      
      index = other_def.desc_id >> Math.log2(@bitwidth).to_i
      raise "bad index or trait_bitmap_size" unless index < trait_bitmap_size
      
      bit = other_def.desc_id & (@bitwidth - 1)
      traits_bitmap[index] |= (1 << bit)
    end
    traits_bitmap_global = gen_global_for_const \
      @isize.const_array(traits_bitmap.map { |bits| @isize.const_int(bits) })
    
    # Create an intermediary function that strips the mutator_gtype receiver
    # from the arguments forwarded to the gfunc we actually want to call.
    orig_block = @builder.insert_block
    via_llvm_func =
      @mod.functions.add(
        "#{gfunc.llvm_name}.VIA.#{mutator_gtype.type_def.llvm_name}",
        mutator_call_gfunc.virtual_llvm_func.function_type.params_types,
        mutator_call_gfunc.virtual_llvm_func.function_type.return_type,
      ) do |fn|
        gen_func_start(fn)
        @builder.ret @builder.call(gfunc.llvm_func, [fn.params[1]])
        gen_func_end
      end
    
    # Go back to the original block that we were at before making this function.
    @builder.position_at_end(orig_block)
    
    # Create a vtable that places our via function in the proper index.
    vtable = mutator_gtype.gen_vtable(self)
    vtable[mutator_call_gfunc.vtable_index] =
      @llvm.const_bit_cast(via_llvm_func.to_value, @ptr)
    
    # Generate a type descriptor, so this can masquerade as a real primitive.
    desc = gen_global_for_const(mutator_gtype.desc_type.const_struct [
      @i32.const_int(0xFFFF_FFFF),         # 0: id
      @i32.const_int(abi_size_of(@ptr)),   # 1: size
      @i32_0,                              # 2: field_count (tuples only)
      @i32_0,                              # 3: field_offset
      @obj_ptr.null,                       # 4: instance
      @trace_fn_ptr.null,                  # 5: trace fn
      @trace_fn_ptr.null,                  # 6: serialise trace fn
      @serialise_fn_ptr.null,              # 7: serialise fn
      @deserialise_fn_ptr.null,            # 8: deserialise fn
      @custom_serialise_space_fn_ptr.null, # 9: custom serialise space fn
      @custom_deserialise_fn_ptr.null,     # 10: custom deserialise fn
      @dispatch_fn_ptr.null,               # 11: dispatch fn
      @final_fn_ptr.null,                  # 12: final fn
      @i32.const_int(-1),                  # 13: event notify
      traits_bitmap_global,                # 14: traits bitmap
      @pptr.null,                          # 15: field descriptors
      @ptr.const_array(vtable),            # 16: vtable
    ])
    
    # Finally, create the singleton "instance" for this fake primitve.
    gen_global_for_const(@obj.const_struct([desc]))
  end
  
  def gen_sequence(expr : AST::Group)
    # Use None as a value when the sequence group size is zero.
    if expr.terms.size == 0
      type_of(expr).is_none!
      return gen_none
    end
    
    # TODO: Push a scope frame?
    
    final : LLVM::Value? = nil
    expr.terms.each { |term| final = gen_expr(term) }
    final.not_nil!
    
    # TODO: Pop the scope frame?
  end
  
  def gen_dynamic_array(expr : AST::Group)
    gtype = gtype_of(expr)
    
    receiver = gen_alloc(gtype, "#{gtype.type_def.llvm_name}.new")
    size_arg = @i64.const_int(expr.terms.size)
    @builder.call(gtype.gfuncs["new"].llvm_func, [receiver, size_arg])
    
    expr.terms.each do |term|
      value = gen_expr(term)
      @builder.call(gtype.gfuncs["<<"].llvm_func, [receiver, value])
    end
    
    receiver
  end
  
  # TODO: Use infer resolution for static True/False finding where possible.
  def gen_choice(expr : AST::Choice)
    raise NotImplementedError.new(expr.inspect) if expr.list.empty?
    
    # Get the LLVM type for the phi that joins the final value of each branch.
    # Each such value will needed to be bitcast to the that type.
    phi_type = llvm_type_of(expr)
    
    # Create all of the instruction blocks we'll need for this choice.
    j = expr.list.size
    case_and_cond_blocks = [] of LLVM::BasicBlock
    expr.list.each_cons(2).to_a.each_with_index do |(fore, aft), i|
      case_and_cond_blocks << gen_block("case#{i + 1}of#{j}_choice")
      case_and_cond_blocks << gen_block("cond#{i + 2}of#{j}_choice")
    end
    case_and_cond_blocks << gen_block("case#{j}of#{j}_choice")
    post_block = gen_block("after#{j}of#{j}_choice")
    
    # Generate code for the first condition - we always start by running this.
    cond_value = gen_as_cond(gen_expr(expr.list.first[0]))
    
    # Generate the interacting code for each consecutive pair of cases.
    phi_blocks = [] of LLVM::BasicBlock
    phi_values = [] of LLVM::Value
    expr.list.each_cons(2).to_a.each_with_index do |(fore, aft), i|
      # The case block is the body to execute if the cond_value is true.
      # Otherwise we will jump to the next block, with its next cond_value.
      case_block = case_and_cond_blocks.shift
      next_block = case_and_cond_blocks.shift
      @builder.cond(cond_value, case_block, next_block)
      
      @builder.position_at_end(case_block)
      if func_frame.gfunc.not_nil!.infer[fore[1]].is_a?(Infer::Unreachable)
        # We skip generating code for the case block if it is unreachable,
        # meaning that the cond was deemed at compile time to never be true.
        @builder.unreachable
      else
        # Generate code for the case block that we execute, finishing by
        # jumping to the post block using the `br` instruction, where we will
        # carry the value we just generated as one of the possible phi values.
        value = gen_expr(fore[1])
        unless Jumps.away?(fore[1])
          if Classify.value_needed?(expr)
            value = gen_assign_cast(value, phi_type, fore[1])
            phi_blocks << @builder.insert_block
            phi_values << value
          end
          @builder.br(post_block)
        end
      end
      
      # Generate code for the next block, which is the condition to be
      # checked for truthiness in the next iteration of this loop
      # (or ignored if this is the final case, which must always be exhaustive).
      @builder.position_at_end(next_block)
      cond_value = gen_expr(aft[0])
    end
    
    # This is the final case block - we will jump to it unconditionally,
    # regardless of the truthiness of the preceding cond_value.
    # Choices must always be typechecked to be exhaustive, so we can rest
    # on the guarantee that this cond_value will always be true if we reach it.
    case_block = case_and_cond_blocks.shift
    @builder.br(case_block)
    
    @builder.position_at_end(case_block)
    if func_frame.gfunc.not_nil!.infer[expr.list.last[1]].is_a?(Infer::Unreachable)
      # We skip generating code for the case block if it is unreachable,
      # meaning that the cond was deemed at compile time to never be true.
      @builder.unreachable
    else
      # Generate code for the final case block using exactly the same strategy
      # that we used when we generated case blocks inside the loop above.
      value = gen_expr(expr.list.last[1])
      unless Jumps.away?(expr.list.last[1])
        if Classify.value_needed?(expr)
          value = gen_assign_cast(value, phi_type, expr.list.last[1])
          phi_blocks << @builder.insert_block
          phi_values << value
        end
        @builder.br(post_block)
      end
    end
    
    # When we jump away, we can't generate the post block.
    if Jumps.away?(expr)
      post_block.delete
      return gen_none
    end
    
    # Here at the post block, we receive the value that was returned by one of
    # the cases above, using the LLVM mechanism called a "phi" instruction.
    @builder.position_at_end(post_block)
    if Classify.value_needed?(expr)
      @builder.phi(phi_type, phi_blocks, phi_values, "phi_choice")
    else
      gen_none
    end
  end
  
  def gen_loop(expr : AST::Loop)
    # Get the LLVM type for the phi that joins the final value of each branch.
    # Each such value will needed to be bitcast to the that type.
    phi_type = llvm_type_of(expr)
    
    # Prepare to capture state for the final phi.
    phi_blocks = [] of LLVM::BasicBlock
    phi_values = [] of LLVM::Value
    
    # Create all of the instruction blocks we'll need for this loop.
    body_block = gen_block("body_loop")
    else_block = gen_block("else_loop")
    post_block = gen_block("after_loop")
    
    # Start by generating the code to test the condition value.
    # If the cond is true, go to the body block; otherwise, the else block.
    cond_value = gen_as_cond(gen_expr(expr.cond))
    @builder.cond(cond_value, body_block, else_block)
    
    # In the body block, generate code to arrive at the body value,
    # and also generate the condition value code again.
    # If the cond is true, repeat the body block; otherwise, go to post block.
    @builder.position_at_end(body_block)
    body_value = gen_expr(expr.body)
    unless Jumps.away?(expr.body)
      cond_value = gen_expr(expr.cond)
      
      if Classify.value_needed?(expr)
        body_value = gen_assign_cast(body_value, phi_type, expr.body)
        phi_blocks << @builder.insert_block
        phi_values << body_value
      end
      @builder.cond(cond_value, body_block, post_block)
    end
    
    # In the body block, generate code to arrive at the else value,
    # Then skip straight to the post block.
    @builder.position_at_end(else_block)
    else_value = gen_expr(expr.else_body)
    unless Jumps.away?(expr.else_body)
      if Classify.value_needed?(expr)
        else_value = gen_assign_cast(else_value, phi_type, expr.else_body)
        phi_blocks << @builder.insert_block
        phi_values << else_value
      end
      @builder.br(post_block)
    end
    
    # When we jump away, we can't generate the post block.
    if Jumps.away?(expr)
      post_block.delete
      return gen_none
    end
    
    # Here at the post block, we receive the value that was returned by one of
    # the bodies above, using the LLVM mechanism called a "phi" instruction.
    @builder.position_at_end(post_block)
    if Classify.value_needed?(expr)
      @builder.phi(phi_type, phi_blocks, phi_values, "phi_loop")
    else
      gen_none
    end
  end
  
  def gen_try(expr : AST::Try)
    # Get the LLVM type for the phi that joins the final value of each branch.
    # Each such value will needed to be bitcast to the that type.
    phi_type = llvm_type_of(expr)
    
    # Prepare to capture state for the final phi.
    phi_blocks = [] of LLVM::BasicBlock
    phi_values = [] of LLVM::Value
    
    # Create all of the instruction blocks we'll need for this try.
    body_block = gen_block("body_try")
    else_block = gen_block("else_try")
    post_block = gen_block("after_try")
    @try_else_stack << {else_block, [] of LLVM::BasicBlock, [] of LLVM::Value}
    
    # Go straight to the body block from whatever block we are in now.
    @builder.br(body_block)
    
    # Generate the body and get the resulting value, assuming no throw happened.
    # Then continue to the post block.
    @builder.position_at_end(body_block)
    body_value = gen_expr(expr.body)
    unless Jumps.away?(expr.body)
      body_value = gen_assign_cast(body_value, phi_type, expr.body)
      phi_blocks << @builder.insert_block
      phi_values << body_value
      @builder.br(post_block)
    end
    
    # Now start generating the else clause (reached when a throw happened).
    @builder.position_at_end(else_block)
    
    # TODO: Allow an error_phi_type of something other than None.
    error_phi_type = llvm_type_of(@gtypes["None"])
    
    # Catch the thrown error value, by getting the blocks and values from the
    # try_else_stack and using the LLVM mechanism called a "phi" instruction.
    else_stack_tuple = @try_else_stack.pop
    raise "invalid try else stack" unless else_stack_tuple[0] == else_block
    error_value = @builder.phi(
      error_phi_type,
      else_stack_tuple[1],
      else_stack_tuple[2],
      "phi_else_try",
    )
    
    # TODO: allow the else block to reference the error value as a local.
    
    # Generate the body code of the else clause, then proceed to the post block.
    else_value = gen_expr(expr.else_body)
    unless Jumps.away?(expr.else_body)
      else_value = gen_assign_cast(else_value, phi_type, expr.else_body)
      phi_blocks << @builder.insert_block
      phi_values << else_value
      @builder.br(post_block)
    end
    
    # We can't have a phi with no predecessors, so we don't generate it, and
    # return a None value; it won't be used, but this method can't return nil.
    if phi_blocks.empty? && phi_values.empty?
      post_block.delete
      return gen_none
    end
    
    # Here at the post block, we receive the value that was returned by one of
    # the bodies above, using the LLVM mechanism called a "phi" instruction.
    @builder.position_at_end(post_block)
    @builder.phi(phi_type, phi_blocks, phi_values, "phi_try")
  end
  
  def gen_raise_error(error_value = gen_none)
    raise "inconsistent frames" if @frames.size > 1
    
    # TODO: Allow an error value of something other than None.
    error_value = gen_none
    
    # If we have no local try to catch the value, then we return it
    # using the error-able calling convention function style,
    # making (and checking) the assumption that we are in such a function.
    if @try_else_stack.empty?
      calling_convention = func_frame.gfunc.not_nil!.calling_convention
      raise "unsupported empty try else stack for #{calling_convention}" \
        unless calling_convention == :error_cc
      gen_return_using_error_cc(error_value, nil, true)
    else
      # Store the state needed to catch the value in the try else block.
      else_stack_tuple = @try_else_stack.last
      else_stack_tuple[1] << @builder.insert_block
      else_stack_tuple[2] << error_value
      
      # Jump to the try else block.
      @builder.br(else_stack_tuple[0])
    end
  end
  
  def gen_return_using_error_cc(value, value_expr, is_error : Bool)
    raise "inconsistent frames" if @frames.size > 1
    
    value_type = func_frame.llvm_func.return_type.struct_element_types[0]
    value = gen_assign_cast(value, value_type, value_expr) unless is_error
    
    tuple = func_frame.llvm_func.return_type.undef
    tuple = @builder.insert_value(tuple, value, 0)
    tuple = @builder.insert_value(tuple, is_error ? @i1_true : @i1_false, 1)
    @builder.ret(tuple)
  end
  
  def gen_yield(expr : AST::Yield)
    raise "inconsistent frames" if @frames.size > 1
    
    @di.set_loc(expr)
    
    gfunc = func_frame.gfunc.not_nil!
    
    # First, we must know which yield this is in the function -
    # each yield expression has a uniquely associated index.
    yield_index = ctx.inventory.yields(gfunc.func).index(expr).not_nil!
    
    # Generate code for the values of the yield, and capture the values.
    yield_values = expr.terms.map { |term| gen_expr(term).as(LLVM::Value) }
    
    # Determine the continue function to use, based on the index of this yield.
    next_func = gfunc.continuation_llvm_funcs[yield_index]
    next_func = @llvm.const_bit_cast(next_func.to_value, @ptr)
    
    # Generate the return statement, which terminates this basic block and
    # returns the tuple of the yield value and continuation data to the caller.
    gen_yield_return_using_yield_cc(next_func, yield_values)
    
    # Now start generating the code that comes after the yield expression.
    # Note that this code block will be dead code (with "no predecessors")
    # in all but one of the continue functions that we generate - the one
    # continue function we grabbed above (which jumps to this block on entry).
    after_block = gfunc.after_yield_blocks[yield_index]
    @builder.position_at_end(after_block)
    
    # Finally, use the "yield in" value returned from the caller.
    # However, if we're not actually in a continuation function, then this
    # "yield in" value won't be present in the parameters and we need to
    # create an undefined value of the right type to fake it; but fear not,
    # that junk value won't be used because that code won't ever be reached.
    if gfunc.continuation_llvm_funcs.includes?(func_frame.llvm_func)
      func_frame.llvm_func.params[1]
    else
      gfunc.continuation_llvm_func_ptr.element_type.params_types[1].undef
    end
  end
  
  def gen_yield_return_using_yield_cc(next_func : LLVM::Value, values)
    raise "inconsistent frames" if @frames.size > 1
    
    gfunc = func_frame.gfunc.not_nil!
    
    # Cast the given values to the appropriate type.
    return_type = gfunc.yield_cc_yield_return_type
    cast_values =
      values.map_with_index do |value, index|
        llvm_type = return_type.struct_element_types[index + 1]
        gen_assign_cast(value, llvm_type, nil)
      end
    
    # Grab the continuation value from local memory and set the next func.
    cont = func_frame.continuation_value
    gfunc.continuation_info.set_next_func(cont, next_func)
    
    # Return the tuple: {continuation_value, *values}
    tuple = return_type.undef
    tuple = @builder.insert_value(tuple, cont, 0)
    cast_values.each_with_index do |cast_value, index|
      tuple = @builder.insert_value(tuple, cast_value, index + 1)
    end
    tuple.name = "YIELD.RETURN"
    @builder.ret(gen_struct_bit_cast(tuple, func_frame.llvm_func.return_type))
  end
  
  def gen_final_return_using_yield_cc(value)
    raise "inconsistent frames" if @frames.size > 1
    
    gfunc = func_frame.gfunc.not_nil!
    
    # Cast the given value to the appropriate type.
    return_type = func_frame.gfunc.not_nil!.yield_cc_final_return_type
    llvm_type = return_type.struct_element_types[1]
    cast_value = gen_assign_cast(value, llvm_type, nil)
    
    # Grab the continuation value from local memory and clear the next func.
    cont = func_frame.continuation_value
    gfunc.continuation_info.set_next_func(cont, nil)
    
    # Return the tuple: {continuation_value, value}
    tuple = return_type.undef
    tuple = @builder.insert_value(tuple, cont, 0)
    tuple = @builder.insert_value(tuple, cast_value, 1)
    tuple.name = "FINAL.RETURN"
    @builder.ret(gen_struct_bit_cast(tuple, func_frame.llvm_func.return_type))
  end
  
  def gen_struct_bit_cast(value : LLVM::Value, to_type : LLVM::Type)
    # LLVM doesn't allow directly casting to/from structs, so we cheat a bit
    # with an alloca in between the two as a pointer that we can cast.
    alloca = gen_alloca(value.type, "#{value.name}.PTR")
    @builder.store(value, alloca)
    @builder.load(
      @builder.bit_cast(
        alloca,
        to_type.pointer,
        "#{value.name}.CAST.PTR",
      ),
      "#{value.name}.CAST",
    )
  end
  
  # Create an alloca at the entry block then return us back to whence we came.
  def gen_alloca(llvm_type : LLVM::Type, name : String)
    gen_at_entry do
      @builder.alloca(llvm_type, name)
    end
  end
  
  def gen_at_entry
    # We need to take note of the current block first, then move to the
    # entry block for inserting whatever we want to insert here.
    # We usually have to do this because otherwise we might accidentally create
    # something in a block and reuse it from another block that does not
    # follow the first block, resulting in invalid IR ("does not dominate").
    # All blocks follow the entry block (it dominates all other blocks),
    # so this is a surefire safe place to do whatever it is we need to declare.
    orig_block = @builder.insert_block
    entry_block = gen_frame.entry_block
    
    if entry_block.instructions.empty?
      @builder.position_at_end(entry_block)
    else
      @builder.position_before(entry_block.instructions.first)
    end
    
    # Let the caller declare what they may
    result = yield
    
    # Go back to the original block that we were at before this function.
    @builder.position_at_end(orig_block)
    
    # Return the result of the yielded block.
    result
  end
  
  DESC_ID                        = 0
  DESC_SIZE                      = 1
  DESC_FIELD_COUNT               = 2
  DESC_FIELD_OFFSET              = 3
  DESC_INSTANCE                  = 4
  DESC_TRACE_FN                  = 5
  DESC_SERIALISE_TRACE_FN        = 6
  DESC_SERIALISE_FN              = 7
  DESC_DESERIALISE_FN            = 8
  DESC_CUSTOM_SERIALISE_SPACE_FN = 9
  DESC_CUSTOM_DESERIALISE_FN     = 10
  DESC_DISPATCH_FN               = 11
  DESC_FINAL_FN                  = 12
  DESC_EVENT_NOTIFY              = 13
  DESC_TRAITS                    = 14
  DESC_FIELDS                    = 15
  DESC_VTABLE                    = 16
  
  # This defines the generic LLVM struct type for what a type descriptor holds.
  # The type descriptor for each type uses a more specific version of this.
  # The order and sizes here must exactly match what is expected by the runtime,
  # and they should correlate to the constants above.
  def gen_desc_basetype
    @desc.struct_set_body [
      @i32,                           # 0: id
      @i32,                           # 1: size
      @i32,                           # 2: field_count
      @i32,                           # 3: field_offset
      @obj_ptr,                       # 4: instance
      @trace_fn_ptr,                  # 5: trace fn
      @trace_fn_ptr,                  # 6: serialise trace fn
      @serialise_fn_ptr,              # 7: serialise fn
      @deserialise_fn_ptr,            # 8: deserialise fn
      @custom_serialise_space_fn_ptr, # 9: custom serialise space fn
      @custom_deserialise_fn_ptr,     # 10: custom deserialise fn
      @dispatch_fn_ptr,               # 11: dispatch fn
      @final_fn_ptr,                  # 12: final fn
      @i32,                           # 13: event notify
      @isize.array(0).pointer,        # 14: traits bitmap
      @pptr,                          # 15: TODO: fields descriptors
      @ptr.array(0),                  # 16: vtable
    ]
  end
  
  # This defines a more specific struct type than the above function,
  # tailored to the specific type definition and its virtual table size.
  # The actual type descriptor value for the type is an instance of this.
  def gen_desc_type(type_def : Reach::Def, vtable_size : Int32) : LLVM::Type
    @llvm.struct [
      @i32,                                    # 0: id
      @i32,                                    # 1: size
      @i32,                                    # 2: field_count
      @i32,                                    # 3: field_offset
      @obj_ptr,                                # 4: instance
      @trace_fn_ptr,                           # 5: trace fn
      @trace_fn_ptr,                           # 6: serialise trace fn
      @serialise_fn_ptr,                       # 7: serialise fn
      @deserialise_fn_ptr,                     # 8: deserialise fn
      @custom_serialise_space_fn_ptr,          # 9: custom serialise space fn
      @custom_deserialise_fn_ptr,              # 10: custom deserialise fn
      @dispatch_fn_ptr,                        # 11: dispatch fn
      @final_fn_ptr,                           # 12: final fn
      @i32,                                    # 13: event notify
      @isize.array(trait_bitmap_size).pointer, # 14: traits bitmap
      @pptr,                                   # 15: TODO: fields descriptors
      @ptr.array(vtable_size),                 # 16: vtable
    ], "#{type_def.llvm_name}.DESC"
  end
  
  # This defines a global constant for the type descriptor of a type,
  # which is held as the first value in an object, used for identifying its
  # type at runtime, as well as a host of other functions related to dealing
  # with objects in the runtime, such as allocating them and tracing them.
  def gen_desc(gtype, vtable)
    type_def = gtype.type_def
    
    desc = @mod.globals.add(gtype.desc_type, "#{type_def.llvm_name}.DESC")
    desc.linkage = LLVM::Linkage::LinkerPrivate
    desc.global_constant = true
    desc
    
    abi_size = abi_size_of(gtype.struct_type)
    field_offset =
      if gtype.fields.empty?
        0
      else
        @target_machine.data_layout.offset_of_element(
          gtype.struct_type,
          gtype.field_index(gtype.fields[0][0]),
        )
      end
    
    dispatch_fn =
      if type_def.is_actor?
        @mod.functions.add("#{type_def.llvm_name}.DISPATCH", @dispatch_fn)
      else
        @dispatch_fn_ptr.null
      end
    
    trace_fn =
      if type_def.has_desc? && gtype.fields.any?(&.last.trace_needed?)
        @mod.functions.add("#{type_def.llvm_name}.TRACE", @trace_fn)
      else
        @trace_fn_ptr.null
      end
    
    # Generate a bitmap of one or more integers in which each bit represents
    # a trait in the program, with types that implement that trait having
    # the corresponding bit set in their version of the bitmap.
    # This is used for runtime type matching against abstract types (traits).
    is_asio_event_notify = false
    traits_bitmap = trait_bitmap_size.times.map { 0 }.to_a
    infer = ctx.infer[gtype.type_def.reified]
    ctx.reach.each_type_def.each do |other_def|
      if infer.is_subtype?(gtype.type_def.reified, other_def.reified)
        next if gtype.type_def == other_def
        raise "can't be subtype of a concrete" unless other_def.is_abstract?
        
        index = other_def.desc_id >> Math.log2(@bitwidth).to_i
        raise "bad index or trait_bitmap_size" unless index < trait_bitmap_size
        
        bit = other_def.desc_id & (@bitwidth - 1)
        traits_bitmap[index] |= (1 << bit)
        
        # Take special note if this type is a subtype of AsioEventNotify.
        is_asio_event_notify = true if other_def.llvm_name == "AsioEventNotify"
      end
    end
    traits_bitmap_global = gen_global_for_const \
      @isize.const_array(traits_bitmap.map { |bits| @isize.const_int(bits) })
    
    # If this type is an AsioEventNotify, then take note of the vtable index
    # of the _event_notify behaviour that the ASIO runtime will send to.
    # Otherwise, an index of -1 indicates that the runtime should *not* send.
    event_notify_vtable_index = @i32.const_int(
      is_asio_event_notify ? gtype["_event_notify"].vtable_index : -1
    )
    
    desc.initializer = gtype.desc_type.const_struct [
      @i32.const_int(type_def.desc_id),      # 0: id
      @i32.const_int(abi_size),              # 1: size
      @i32_0,                                # 2: TODO: field_count (tuples only)
      @i32.const_int(field_offset),          # 3: field_offset
      @obj_ptr.null,                         # 4: instance
      trace_fn.to_value,                     # 5: trace fn
      @trace_fn_ptr.null,                    # 6: serialise trace fn TODO: @#{llvm_name}.SERIALISETRACE
      @serialise_fn_ptr.null,                # 7: serialise fn TODO: @#{llvm_name}.SERIALISE
      @deserialise_fn_ptr.null,              # 8: deserialise fn TODO: @#{llvm_name}.DESERIALISE
      @custom_serialise_space_fn_ptr.null,   # 9: custom serialise space fn
      @custom_deserialise_fn_ptr.null,       # 10: custom deserialise fn
      dispatch_fn.to_value,                  # 11: dispatch fn
      @final_fn_ptr.null,                    # 12: final fn
      event_notify_vtable_index,             # 13: event notify TODO
      traits_bitmap_global,                  # 14: traits bitmap
      @pptr.null,                            # 15: TODO: fields
      @ptr.const_array(vtable),              # 16: vtable
    ]
    
    desc
  end
  
  # This defines the LLVM struct type for objects of this type.
  def gen_struct_type(gtype)
    elements = [] of LLVM::Type
    
    # All struct types start with the type descriptor (abbreviated "desc").
    # Even types with no desc have a singleton with a desc.
    # The values without a desc do not use this struct_type at all anyway.
    elements << gtype.desc_type.pointer
    
    # Actor types have an actor pad, which holds runtime internals containing
    # things like the message queue used to deliver runtime messages.
    elements << @actor_pad if gtype.type_def.has_actor_pad?
    
    # Each field of the type is an additional element in the struct type.
    gtype.fields.each { |name, t| elements << llvm_mem_type_of(t) }
    
    # The struct was previously opaque with no body. We now fill it in here.
    gtype.struct_type.struct_set_body(elements)
  end
  
  # This defines the global singleton stateless value associated with this type.
  # This value is invoked whenever you reference the type with as a `non`,
  # acting as a runtime representation of a type itself rather than an instance.
  # For primitives, this is the only value you'll ever see.
  def gen_singleton(gtype)
    global = @mod.globals.add(gtype.struct_type, gtype.type_def.llvm_name)
    global.linkage = LLVM::Linkage::LinkerPrivate
    global.global_constant = true
    
    # For allocated types, we still generate a singleton for static use,
    # but we need to populate the fields with something - we use zeros.
    # We are relying on the reference capabilities part of the type system
    # to prevent such singletons from ever having their fields dereferenced.
    elements = gtype.struct_type.struct_element_types[1..-1].map(&.null)
    
    # The first element is always the type descriptor.
    elements.unshift(gtype.desc)
    
    global.initializer = gtype.struct_type.const_struct(elements)
    global
  end
  
  # This generates the code that allocates an object of the given type.
  # This is the first step before actually calling the constructor of it.
  def gen_alloc(gtype : GenType, name : String)
    return gen_alloc_actor(gtype, name) if gtype.type_def.is_actor?
    
    value = gen_alloc(gtype.struct_type, name)
    gen_put_desc(value, gtype, name)
    value
  end
  
  # This generates the code that allocates an object of any given LLVM type.
  # It is used by the other implementation of this function defined above.
  def gen_alloc(llvm_type : LLVM::Type, name : String)
    size = abi_size_of(llvm_type)
    size = 1 if size == 0
    args = [pony_ctx]
    
    value =
      if size <= PonyRT::HEAP_MAX
        index = PonyRT.heap_index(size).to_i32
        args << @i32.const_int(index)
        # TODO: handle case where final_fn is present (pony_alloc_small_final)
        @builder.call(@mod.functions["pony_alloc_small"], args, "#{name}.MEM")
      else
        args << @isize.const_int(size)
        # TODO: handle case where final_fn is present (pony_alloc_large_final)
        @builder.call(@mod.functions["pony_alloc_large"], args, "#{name}.MEM")
      end
    
    @builder.bit_cast(value, llvm_type.pointer, name)
  end
  
  # This generates the special kind of allocation needed by actors,
  # invoked by the above function when the type being allocated is an actor.
  def gen_alloc_actor(gtype, name, become_now = false)
    allocated = @builder.call(@mod.functions["pony_create"], [
      pony_ctx,
      gen_get_desc_opaque(gtype),
    ], "#{name}.OPAQUE")
    
    if become_now
      @builder.call(@mod.functions["pony_become"], [
        gen_frame.pony_ctx, allocated])
    end
    
    @builder.bit_cast(allocated, gtype.struct_ptr, name)
  end
  
  # Get the global constant value for the type descriptor of the given type.
  def gen_get_desc_opaque(gtype : GenType)
    @llvm.const_bit_cast(gtype.desc, @desc_ptr)
  end
  
  # Get the global constant value for the type descriptor of the given type.
  def gen_get_desc_opaque(value : LLVM::Value)
    desc = gen_get_desc(value)
    @builder.bit_cast(desc, @desc_ptr, "#{value.name}.OPAQUE")
  end
  
  # Dereference the type descriptor header of the given LLVM value,
  # loading the type descriptor of the object at runtime.
  # Prefer the above function instead when the type is statically known.
  def gen_get_desc(value : LLVM::Value)
    value_type = value.type
    raise "not a struct pointer: #{value}" \
      unless value_type.kind == LLVM::Type::Kind::Pointer \
        && value_type.element_type.kind == LLVM::Type::Kind::Struct
    
    desc_gep = @builder.struct_gep(value, 0, "#{value.name}.DESC.GEP")
    @builder.load(desc_gep, "#{value.name}.DESC")
  end
  
  def gen_put_desc(value, gtype, name = "")
    desc_p = @builder.struct_gep(value, 0, "#{name}.DESC.GEP")
    @builder.store(gtype.desc, desc_p)
    # TODO: tbaa? (from set_descriptor in libponyc/codegen/gencall.c)
  end
  
  def gen_local_gep(ref, llvm_type)
    gfunc = func_frame.gfunc.not_nil!
    
    # If this is a yielding function, we store locals in the continuation data.
    # Otherwise, we store each in its own alloca, which we create at the entry.
    if gfunc.calling_convention == :yield_cc
      cont = func_frame.continuation_value
      gep = gfunc.continuation_info.struct_gep_for_local(cont, ref)
      # TODO: bitcast to llvm_type?
      @builder.bit_cast(gep, llvm_type.pointer)
    else
      gen_at_entry do
        @builder.alloca(llvm_type, ref.name)
      end
    end
    .tap { |gep| @di.declare_local(ref, type_of(ref.defn), gep) }
  end
  
  def gen_field_gep(name, gtype = func_frame.gtype.not_nil!)
    raise "inconsistent frames" if @frames.size > 1
    object = func_frame.receiver_value
    @builder.struct_gep(object, gtype.field_index(name), "@.#{name}.GEP")
  end
  
  def gen_field_load(name, gtype = func_frame.gtype.not_nil!)
    @builder.load(gen_field_gep(name, gtype), "@.#{name}")
  end
  
  def gen_field_store(name, value)
    @builder.store(value, gen_field_gep(name))
  end
  
  # Calculate the number of @bitwidth-sized integers  (i.e. @isize)
  # would be needed to hold a single bit for each trait in the trait_count.
  # For example, if there are 64 traits, the trait_bitmap_size is 2,
  # but if there is a 65th trait, the trait_bitmap_size increases to 3,
  # because another integer will be added to hold that many bits.
  def trait_bitmap_size
    trait_count = @ctx.not_nil!.reach.trait_count
    ((trait_count + (@bitwidth - 1)) & ~(@bitwidth - 1)) \
      >> Math.log2(@bitwidth).to_i
  end
  
  def gen_trace_unknown(dst, ponyrt_trace_kind)
    @builder.call(@mod.functions["pony_traceunknown"], [
      pony_ctx,
      @builder.bit_cast(dst, @obj_ptr, "#{dst.name}.OPAQUE"),
      @i32.const_int(ponyrt_trace_kind),
    ])
  end
  
  def gen_trace_known(dst, src_type, ponyrt_trace_kind)
    src_gtype = @gtypes[ctx.reach[src_type.single!].llvm_name]
    
    @builder.call(@mod.functions["pony_traceknown"], [
      pony_ctx,
      @builder.bit_cast(dst, @obj_ptr, "#{dst.name}.OPAQUE"),
      @builder.bit_cast(src_gtype.desc, @desc_ptr, "#{dst.name}.DESC"),
      @i32.const_int(ponyrt_trace_kind),
    ])
  end
  
  def gen_trace_dynamic(dst, src_type, dst_type, after_block)
    if src_type.is_union?
      src_type.union_children.each do |child_type|
        gen_trace_dynamic(dst, child_type, dst_type, after_block)
      end
      gen_trace_unknown(dst, PonyRT::TRACE_OPAQUE)
    elsif src_type.singular?
      src_type_def = src_type.single_def!(ctx)
      
      # We can't trace it if it doesn't have a descriptor,
      # and we shouldn't trace it if it isn't runtime-allocated.
      return unless src_type_def.has_desc? && src_type_def.has_allocation?
      
      # Generate code to check if this value is a subtype of this at runtime.
      is_subtype = gen_check_subtype_at_runtime(dst, src_type)
      true_block = gen_block("trace.is_subtype_of.#{src_type.show_type}")
      false_block = gen_block("trace.not_subtype_of.#{src_type.show_type}")
      @builder.cond(is_subtype, true_block, false_block)
      
      # In the block in which the value was proved to indeed be a subtype,
      # Determine the mutability kind to use, then construct a newly refined
      # destination type to trace for, recursing/delegating back to gen_trace.
      @builder.position_at_end(true_block)
      mutability = src_type.trace_mutability_of_nominal(
        ctx.infer[src_type_def.reified],
        dst_type,
      )
      refined_dst_type =
        case mutability
        when :mutable   then src_type_def.as_ref("iso")
        when :immutable then src_type_def.as_ref("val")
        when :opaque    then src_type_def.as_ref("tag")
        when :non       then src_type_def.as_ref("non")
        else
          raise NotImplementedError.new([src_type, dst_type])
        end
      gen_trace(dst, dst, src_type, refined_dst_type)
      
      # If we've traced as mutable or immutable, we're done with this element;
      # otherwise, we continue tracing as if the match had been false.
      case mutability
      when :mutable, :immutable then @builder.br(after_block)
      else                           @builder.br(false_block)
      end
      
      # Carry on to the next elements, continuing from the false block.
      @builder.position_at_end(false_block)
    else
      raise NotImplementedError.new(src_type)
    end
  end
  
  def gen_trace(src : LLVM::Value, dst : LLVM::Value, src_type, dst_type)
    if src_type == dst_type
      trace_kind = src_type.trace_kind
    else
      # TODO: When is this true and not true? Do we have the right equivalency test?
      # As of the time of this writing, this is unreachable because
      # we always specify the same src_type and dst_type in the caller.
      raise "halt; verify the circumstances of how we arrived here"
      trace_kind = src_type.trace_kind_with_dst_cap(dst_type.trace_kind)
    end
    
    case trace_kind
    when :machine_word
      if dst_type.trace_kind == :machine_word
        # Do nothing - no need to trace this value since it isn't boxed.
      else
        # The value is indeed boxed and has a type descriptor; trace it.
        gen_trace_known(dst, src_type, PonyRT::TRACE_IMMUTABLE)
      end
    when :mut_known
      gen_trace_known(dst, src_type, PonyRT::TRACE_MUTABLE)
    when :val_known, :non_known
      gen_trace_known(dst, src_type, PonyRT::TRACE_IMMUTABLE)
    when :tag_known
      gen_trace_known(dst, src_type, PonyRT::TRACE_OPAQUE)
    when :mut_unknown
      gen_trace_unknown(dst, PonyRT::TRACE_MUTABLE)
    when :val_unknown, :non_unknown
      gen_trace_unknown(dst, PonyRT::TRACE_IMMUTABLE)
    when :tag_unknown
      gen_trace_unknown(dst, PonyRT::TRACE_OPAQUE)
    when :static
      raise NotImplementedError.new("static") # TODO
    when :dynamic
      after_block = gen_block("after_dynamic_trace")
      gen_trace_dynamic(dst, src_type, dst_type, after_block)
      @builder.br(after_block)
      @builder.position_at_end(after_block)
    when :tuple
      raise NotImplementedError.new("tuple") # TODO
    else
      raise NotImplementedError.new(trace_kind)
    end
  end
  
  def gen_send_impl(gtype, gfunc)
    fn = gfunc.send_llvm_func
    gen_func_start(fn)
    
    # Get the message type and virtual table index to use.
    msg_type = gfunc.send_msg_llvm_type
    vtable_index = gfunc.vtable_index
    
    # Allocate a message object of the specific size/type used by this function.
    msg_size = abi_size_of(msg_type)
    pool_index = PonyRT.pool_index(msg_size)
    msg_opaque = @builder.call(@mod.functions["pony_alloc_msg"],
      [@i32.const_int(pool_index), @i32.const_int(vtable_index)], "msg.OPAQUE")
    msg = @builder.bit_cast(msg_opaque, msg_type.pointer, "msg")
    
    src_types = [] of Reach::Ref
    dst_types = [] of Reach::Ref
    src_values = [] of LLVM::Value
    dst_values = [] of LLVM::Value
    needs_trace = false
    
    # Store all forwarding arguments in the message object.
    msg_type.struct_element_types.each_with_index do |elem_type, i|
      next if i < 3 # skip the first 3 boilerplate fields in the message
      param = fn.params[i - 3 + 1] # skip 3 fields, skip 1 param (the receiver)
      param.name = "param.#{i - 2}"
      
      arg = gfunc.func.params.not_nil!.terms[i - 3] # skip 3 fields
      dst_types << type_of(arg, gfunc)
      src_types << dst_types.last # TODO: are these ever different?
      
      needs_trace ||= src_types.last.trace_needed?(dst_types.last)
      
      # Cast the argument to the correct type and store it in the message.
      cast_arg = gen_assign_cast(param, elem_type, nil)
      arg_gep = @builder.struct_gep(msg, i, "msg.#{i - 2}.GEP")
      @builder.store(cast_arg, arg_gep)
      
      src_values << param
      dst_values << cast_arg
    end
    
    if needs_trace
      @builder.call(@mod.functions["pony_gc_send"], [pony_ctx])
      
      src_values.each_with_index do |src_value, i|
        gen_trace(src_value, dst_values[i], src_types[i], dst_types[i])
      end
      
      @builder.call(@mod.functions["pony_send_done"], [pony_ctx])
    end
    
    # Send the message.
    @builder.call(@mod.functions["pony_sendv_single"], [
      pony_ctx,
      @builder.bit_cast(fn.params[0], @obj_ptr, "@.OPAQUE"),
      msg_opaque,
      msg_opaque,
      @i1.const_int(1)
    ])
    
    # Return None.
    @builder.ret(gen_none)
    
    gen_func_end
  end
  
  def gen_trace_impl(gtype : GenType)
    raise "inconsistent frames" if @frames.size > 1
    
    # Get the reference to the trace function declared earlier.
    # We'll fill in the implementation of that function now.
    fn = @mod.functions["#{gtype.type_def.llvm_name}.TRACE"]?
    return unless fn
    
    fn.unnamed_addr = true
    fn.call_convention = LLVM::CallConvention::C
    fn.linkage = LLVM::Linkage::External
    
    gen_func_start(fn)
    
    fn.params[0].name = "PONY_CTX"
    fn.params[1].name = "@.OPAQUE"
    func_frame.pony_ctx = fn.params[0]
    func_frame.receiver_value =
      @builder.bit_cast(fn.params[1], gtype.struct_ptr, "@")
    
    gtype.fields.each do |field_name, field_type|
      next unless field_type.trace_needed?
      
      field = gen_field_load(field_name, gtype)
      gen_trace(field, field, field_type, field_type)
    end
    
    @builder.ret
    gen_func_end
  end
  
  def gen_dispatch_impl(gtype : GenType)
    raise "inconsistent frames" if @frames.size > 1
    
    # Get the reference to the dispatch function declared earlier.
    # We'll fill in the implementation of that function now.
    fn = @mod.functions["#{gtype.type_def.llvm_name}.DISPATCH"]
    fn.unnamed_addr = true
    fn.call_convention = LLVM::CallConvention::C
    fn.linkage = LLVM::Linkage::External
    
    gen_func_start(fn)
    
    fn.params[0].name = "PONY_CTX"
    fn.params[1].name = "@.OPAQUE"
    fn.params[2].name = "msg"
    
    func_frame.pony_ctx = fn.params[0]
    receiver_opaque = fn.params[1]
    func_frame.receiver_value = receiver =
      @builder.bit_cast(receiver_opaque, gtype.struct_ptr, "@")
    
    # Get the message id from the first field of the message object
    # (which was the third parameter to this function).
    msg_id_gep = @builder.struct_gep(fn.params[2], 1, "msg.id.GEP")
    msg_id = @builder.load(msg_id_gep, "msg.id")
    
    # Capture the current insert block so we can come back to it later,
    # after we jump around into each case block that we need to generate.
    orig_block = @builder.insert_block
    
    # Generate the case block for each async function of this type,
    # mapped by the message id that corresponds to that function.
    cases = {} of LLVM::Value => LLVM::BasicBlock
    gtype.gfuncs.each do |func_name, gfunc|
      # Only look at functions with the async tag.
      next unless gfunc.func.has_tag?(:async)
      
      # Use the vtable index of the function as the message id to look for.
      id = @i32.const_int(gfunc.vtable_index)
      
      # Create the block to execute when the message id matches.
      cases[id] = block = gen_block("DISPATCH.#{func_name}")
      @builder.position_at_end(block)
      
      src_types = [] of Reach::Ref
      dst_types = [] of Reach::Ref
      src_values = [] of LLVM::Value
      dst_values = [] of LLVM::Value
      needs_trace = false
      
      # Destructure args from the message.
      msg_type = gfunc.send_msg_llvm_type
      msg = @builder.bit_cast(fn.params[2], msg_type.pointer, "msg.#{func_name}")
      msg_type.struct_element_types.each_with_index do |elem_type, i|
        next if i < 3 # skip the first 3 boilerplate fields in the message
        
        arg = gfunc.func.params.not_nil!.terms[i - 3] # skip 3 fields
        dst_types << type_of(arg, gfunc)
        src_types << dst_types.last # TODO: are these ever different?
        needs_trace ||= src_types.last.trace_needed?(dst_types.last)
        
        arg_gep = @builder.struct_gep(msg, i, "msg.#{func_name}.#{i - 2}.GEP")
        src_value = @builder.load(arg_gep, "msg.#{func_name}.#{i - 2}")
        src_values << src_value
        
        dst_value = gen_assign_cast(src_value, elem_type, nil)
        dst_values << dst_value
      end
      
      # Prepend the receiver as the first argument, not included in the message.
      args = [receiver] + dst_values
      
      if needs_trace
        @builder.call(@mod.functions["pony_gc_recv"], [pony_ctx])
        
        src_values.each_with_index do |src_value, i|
          gen_trace(src_value, dst_values[i], src_types[i], dst_types[i])
        end
        
        @builder.call(@mod.functions["pony_recv_done"], [pony_ctx])
      end
      
      # Call the underlying function and return void.
      @builder.call(gfunc.llvm_func, args)
      @builder.ret
    end
    
    # We rely on the typechecker to not let us call undefined async functions,
    # so the "else" case of this switch block is to be considered unreachable.
    unreachable_block = gen_block("unreachable_block")
    @builder.position_at_end(unreachable_block)
    # TODO: LLVM infinite loop protection workaround (see gentype.c:503)
    @builder.unreachable
    
    # Finally, return to the original block that we came from and create the
    # switch that maps onto all the case blocks that we just generated.
    @builder.position_at_end(orig_block)
    @builder.switch(msg_id, unreachable_block, cases)
    
    gen_func_end
  end
end
