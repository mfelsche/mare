require "../../../spec_helper"

describe Mare::Compiler::Interpreter::Default do
  it "complains when the function doesn't have a space before the params" do
    source = Mare::Source.new_example <<-SOURCE
    :class Example
      :fun example(x U64)
        x
    SOURCE
    
    expected = <<-MSG
    Expected a term of type: ident or string:
    from (example):2:
      :fun example(x U64)
           ^~~~~~~~~~~~~~
    
    - you probably need to add a space to separate it from this next term:
      from (example):2:
      :fun example(x U64)
                  ^~~~~~~
    MSG
    
    expect_raises Mare::Error, expected do
      Mare::Compiler.compile([source], :import)
    end
  end
  
  it "complains when a capability is specified for a behaviour" do
    source = Mare::Source.new_example <<-SOURCE
    :actor Example
      :be ref example
        None
    SOURCE
    
    expected = <<-MSG
    A behaviour can't have an explicit receiver capability:
    from (example):2:
      :be ref example
          ^~~
    MSG
    
    expect_raises Mare::Error, expected do
      Mare::Compiler.compile([source], :import)
    end
  end
end
