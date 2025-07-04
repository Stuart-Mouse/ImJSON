# Notes to myself, for future implementation
    
## Order-dependent Parsing

Tsoding makes a good point about objects with this kind of structure, 
where the value object needs to be parsed differently depending on the type:
```
{
    type: "Foo",
    value: { ... }
}
```

If the value object is ordered before the value in the parent object, then we have a problem.
The simple solution is just to say that the type must always come first, but that's probably technically not compliant with some JSON spec which I just assume says objects must be parsed in an order-independent way.
Perhaps we could implement some special flag on parse_field that tells the parser to scan ahead for this field in the object, that way if it is present we get its value right away or report an error.
This scanning ahead could be more costly but at least it would be an option to get around this scenario.
    
    
## Macro Stuff

This module seems like an interesting test case for macros, since ideally we would be able to add some features that require a sort of communication between nested macros.
A lot of the tricky situations that arise here are in trying to reconcile the more declarative/procedural aspects of parsing JSON.
The mapping from JSON to internal values is best described declaratively, but any validation code we want to insert into the process needs to be procedural, and arbitrary.
We'd like for the JSON parsing control flow to be automated away as much as possible, but we still want some user-defined flow control within particular blocks.
No matter how we end up factoring it, the control flow should at least be clear to the user.

TODO: 
    Implement basic procs for getting the value of a field as a specific type, so that people aren't forced to use reflection.
        This is pretty low priority though since the other things are more interesting and the current method is plenty functional
    
    Prevent checking for matches on fields which have already been parsed.
        We could accomplish this pretty easily if we had some 'static' specific for variables,
        since we could just put a static bool in parse_field that gets set when the field is parsed, 
        and check this before doing the full string comparison for the identifier.
        Unfortunately, Jai does not have static variables, so a more creative solution will be required.
    
    Flag fields as .REQUIRED and report an error when the field is not found.
        Like the above feature, this would be mad emuch easier if we had static variables.
        However, even if we did, we would still need some extra logic that would check these values after parsing of the parent object has completed.
        This could be done in a sort of validation pass, where we instrument the body code to pass some constant VALIDATION_PASS flag to all calls to parse_field, then include an #if VALIDATION_PASS code path 
        This would be very magical though, and perhaps that's not what most users would want. However, it's still quite interesting to try!
    
    Early exit loop body once we've found the matching field.
        As it currently stands, we will check the iterator against every parse_field call, every time.
        Ideally, we would break from the body code after a call to parse_field returns true.
        But, we also want to be able to run arbitrary logic when read_field succeeds.
        We could use another for expansion on parse_field that allows for running user code on success, but still allows the the automatic control flow.
        This is another really good use case for the `do` macro, since we want for-like macro capabilities for a non-iteration application.
        
        I've now also tried using a standard macro for parse_object and pasrse_array instead of a for_expansion, 
        but the compiler is still not willing to let me break from one macro into another.
    
The next thing I try will probably be to introspect and instrument the code within the for expansion's inserted body.
The goal will be to find all instances of calls to parse_field, and insert code that will skip these calls after they've been marked as handled.
If we can create an array of state values for the parse_field calls within an aggregate, then we can also mark certain fields as required for the purposes of validation.
we could also have a `validate` macro that the user can put in the body of the for expansion which will be pulled out and inserted after the for loop completes.
    similarly, we could have an on_fail block that is run if parsing fails during the for expansion


## Using the Context

When I first started writing this parser I was using the Context to store the parser data instead of requiring the user to pass an iterator to every parse_xxx call.
While this makes the user code slightly cleaner, I ultimately decided it was better to avoid using the Context in this way unless it was going to provide a substantial benefit.
Maybe in the future it would be worthwhile to try this approach again if it is too cumbersome to try coordinating between nested macros in the way I am thinking may work.

My proposal for a `do` keyword for multi-block macros sort of attempts to solve this case where we would like a macro to set up a temporary context for some complex procedure.
(Perhaps I will rewrite my thoughts on this and try to make a case for its utility.)
There's already several drawbacks in using a standard macro instead of a for expansion (though maybe I could work around some of those),
but the `#code` everywhere is unavoidable and really adds a surprising amount of visual clutter.
 