describe Mare::Compiler::Namespace do
  it "complains when a type has the same name as another" do
    source = Mare::Source.new_example <<-SOURCE
    :class Redundancy
    :actor Redundancy
    SOURCE
    
    expected = <<-MSG
    This type conflicts with another declared type in the same library:
    from (example):2:
    :actor Redundancy
           ^~~~~~~~~~
    
    - the other type with the same name is here:
      from (example):1:
    :class Redundancy
           ^~~~~~~~~~
    MSG
    
    expect_raises Mare::Error, expected do
      Mare::Compiler.compile([source], :namespace)
    end
  end
  
  it "complains when a type has the same name as another" do
    source = Mare::Source.new_example <<-SOURCE
    :class String
    SOURCE
    
    expected = <<-MSG
    This type's name conflicts with a mandatory built-in type:
    from (example):1:
    :class String
           ^~~~~~
    
    - the built-in type is defined here:
      from #{Mare::Compiler.prelude_library.path}/string.mare:1:
    :class val String
               ^~~~~~
    MSG
    
    expect_raises Mare::Error, expected do
      Mare::Compiler.compile([source], :namespace)
    end
  end
  
  # TODO: Figure out how to test these in our test suite - they need a library.
  pending "complains when a bulk-imported type conflicts with another"
  pending "complains when an explicitly imported type conflicts with another"
  pending "complains when an explicitly imported type conflicts with another"
  pending "complains when a type name ends with an exclamation"
  
  it "won't have conflicts with a private type in the prelude library" do
    source = Mare::Source.new_example <<-SOURCE
    :ffi LibPony // defined in the prelude, but private, so no conflict here
    SOURCE
    
    Mare::Compiler.compile([source], :namespace)
  end
  
  # TODO: Figure out how to test these in our test suite - they need a library.
  pending "won't have conflicts with a private type in an imported library"
  pending "complains when trying to explicitly import a private type"
end
