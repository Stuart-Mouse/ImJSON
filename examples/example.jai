#import "Basic";
#import "File";
#import "ImJSON";

Factory :: struct {
    id:       u64;
    name:     string;
    products: [..] Product;
    
    Product :: struct {
        id:             u64;
        name:           string;
        price:          int;
        count_produced: u64;
    }
}

main :: () {
    factory: Factory;
    
    {
        file, file_ok := read_entire_file("factory.json");
        assert(file_ok);
        defer free(file);
        
        parser: JSON_Parser;
        init_parser(*parser, file, "factory.json");
        
        for get_root(*parser) {
            for parse_object(it, "factory") {
                parse_field(it, "id", factory.id);
                parse_field(it, "name", factory.name);
                for parse_array(it, "products") {
                    product := array_add(*factory.products);
                    for parse_object(it) {
                        parse_field(it, "id", product.id);
                        parse_field(it, "name", product.name);
                        parse_field(it, "price", product.price);
                        parse_field(it, "count_produced", product.count_produced);
                    }
                }
            }
        }
    }
    
    print("factory: %\n", factory);
}
