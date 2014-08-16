#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <ffi/ffi.h>
#import <sys/mman.h>
#import "FAAutoInit.h"

typedef struct {
    void *name; // NSString pointer
    const char *encoding;
    NSUInteger size;
    Ivar ivar;
    BOOL shouldCopy; // Only used if ivar is present (setValue:forKey: handles it otherwise)
} _ai_propertyDescription_t;

// Wrapper closure called as a result of a message to `initWith..`
static void _ai_closure(ffi_cif * const aCif,
                        id * const aoRet, void * const aArgs[],
                        _ai_propertyDescription_t * const propertyDescriptions);

static ffi_closure *_ai_ffi_allocClosure(void ** const codePtr);
static ffi_status _ai_ffi_prepareClosure(ffi_closure * const closure, ffi_cif * const cif,
                                         void (*fun)(ffi_cif*,void*,void**,void*),
                                         void * const user_data, void * const codeloc);
static ffi_type *_ai_encodingToFFIType(const char *aEncoding);
static ffi_type *_ai_scalarTypeToFFIType(const char * const aType);


@interface NSObject (AutomaticInitializers)
@end

@interface NSValue (AutomaticInitializers)
// Same as the original, except it returns NSNumbers where appropriate
+ (NSValue *)ai_valueWithBytes:(const void *)aBytes objCType:(const char *)aType;
@end


@implementation NSObject (AutomaticInitializers)

+ (void)load
{
    method_exchangeImplementations(class_getClassMethod([NSObject class], @selector(resolveClassMethod:)),
                                   class_getClassMethod([NSObject class], @selector(_ai_resolveClassMethod:)));
    method_exchangeImplementations(class_getClassMethod([NSObject class], @selector(resolveInstanceMethod:)),
                                   class_getClassMethod([NSObject class], @selector(_ai_resolveInstanceMethod:)));
}

+ (BOOL)_ai_resolveClassMethod:(SEL const)aSel
{
    if(class_conformsToProtocol(self, @protocol(FAAutoInit))) {
        NSString * const sel = NSStringFromSelector(aSel);
        NSRange const withRange = [sel rangeOfString:@"With"];
        if(withRange.location != NSNotFound && [sel hasSuffix:@":"]) {
            NSString *encoding;
            IMP const imp = [self _ai_impForProperties:[self _ai_propertiesFromSelector:[sel substringFromIndex:NSMaxRange(withRange)]]
                                          typeEncoding:&encoding];
            if(imp) {
                class_addMethod(object_getClass(self), aSel, imp, [encoding UTF8String]);
                return YES;
            }
        }
    }
    return [self _ai_resolveClassMethod:aSel];
}

+ (BOOL)_ai_resolveInstanceMethod:(SEL const)aSel
{
    if(class_conformsToProtocol(self, @protocol(FAAutoInit))) {
        NSString * const sel = NSStringFromSelector(aSel);
        if([sel hasPrefix:@"initWith"] && [sel hasSuffix:@":"]) {
            NSString *encoding;
            IMP const imp = [self _ai_impForProperties:[self _ai_propertiesFromSelector:[sel substringFromIndex:8]]
                                          typeEncoding:&encoding];
            if(imp) {
                class_addMethod(self, aSel, imp, [encoding UTF8String]);
                return YES;
            }
        }
    }
    return [self _ai_resolveInstanceMethod:aSel];
}

+ (NSArray *)_ai_propertiesFromSelector:(NSString *)aSelector
{
    NSParameterAssert([aSelector hasSuffix:@":"]);

    aSelector = [aSelector stringByReplacingCharactersInRange:(NSRange) {0, 1}
                                                    withString:[[aSelector substringToIndex:1] lowercaseString]];
    aSelector = [aSelector substringToIndex:[aSelector length]-1];
    return [aSelector componentsSeparatedByString:@":"];
}

+ (IMP)_ai_impForProperties:(NSArray * const)aPropertyNames typeEncoding:(NSString **)aoEncoding
{
    NSParameterAssert([aPropertyNames count] > 0 && aoEncoding);

    NSMutableString * const typeEncoding = [@"@:" mutableCopy];
    _ai_propertyDescription_t * const propertyDescs = malloc(sizeof(_ai_propertyDescription_t)
                                                             * [aPropertyNames count]);

    {
        _ai_propertyDescription_t *currentPropertyDesc = propertyDescs;
        for(NSString *propertyName in aPropertyNames) {
            objc_property_t const property = class_getProperty(self, [propertyName UTF8String]);
            unsigned int attrCount;
            objc_property_attribute_t * const attributes = property_copyAttributeList(property, &attrCount);
            if(!property || !attributes) {
                free(propertyDescs);
                free(attributes);
                return NULL;
            }

            *currentPropertyDesc = (_ai_propertyDescription_t) {
                .name = (__bridge_retained void *)@(property_getName(property))
            };
            for(unsigned int i = 0; i < attrCount; ++i) {
                objc_property_attribute_t const attr = attributes[i];
                if(strncmp("T", attr.name, 1) == 0) {
                    currentPropertyDesc->encoding = strdup(attr.value);
                    NSGetSizeAndAlignment(attr.value, &currentPropertyDesc->size, NULL);
                } else if(strncmp("V", attr.name, 1) == 0)
                    currentPropertyDesc->ivar = class_getInstanceVariable(self, attr.value);
                else if(strncmp("C", attr.name, 1) == 0)
                    currentPropertyDesc->shouldCopy = YES;
            }
            free(attributes);
            if(!currentPropertyDesc->encoding) {
                free(propertyDescs);
                return NULL;
            }
            ++currentPropertyDesc;
        }
    }

    // Create the IMP
    void *imp;
    ffi_closure *closure = _ai_ffi_allocClosure(&imp);
    if(!closure) {
        free(propertyDescs);
        return NULL;
    }

    ffi_type ** const parameterTypes = malloc(sizeof(ffi_type*) * ([aPropertyNames count] + 2));
    parameterTypes[0] = parameterTypes[1] = &ffi_type_pointer;
    for(NSUInteger i = 0; i < [aPropertyNames count]; ++i) {
        parameterTypes[i+2] = _ai_encodingToFFIType(propertyDescs[i].encoding);
    }

    ffi_cif * const cif = malloc(sizeof(ffi_cif));
    if(ffi_prep_cif(cif, FFI_DEFAULT_ABI,
                    (unsigned int)[aPropertyNames count] + 2,
                    &ffi_type_pointer,
                    parameterTypes) == FFI_OK
       && _ai_ffi_prepareClosure(closure, cif,
                                 (void (*)(ffi_cif*,void*,void**,void*))_ai_closure,
                                 propertyDescs,
                                 imp) == FFI_OK)
    {
        *aoEncoding = typeEncoding;
        return imp;
    }
    else {
        free(propertyDescs);
        free(parameterTypes);
        free(cif);
        return NULL;
    }
}

@end

void _ai_closure(ffi_cif * const aCif,
                 id * const aoRet, void * const aArgs[],
                 _ai_propertyDescription_t * const propertyDescs)
{
    id object = *(__strong id *)aArgs[0];
    if(class_isMetaClass(object_getClass(object)))
        object = [object new];
    else
        object = [object init];

    for(unsigned int i = 2; i < aCif->nargs; ++i) {
        _ai_propertyDescription_t const propertyDesc = propertyDescs[i-2];
        if(!propertyDesc.ivar) {
            id const box = *propertyDesc.encoding == _C_ID
                         ? *(__strong id *)aArgs[i]
                         : [NSValue ai_valueWithBytes:aArgs[i] objCType:propertyDesc.encoding];
            [object setValue:box forKey:(__bridge id)propertyDesc.name];
        } else {
            if(*propertyDesc.encoding == _C_ID) {
                id const parameter = *(__unsafe_unretained id *)aArgs[i];
                object_setIvar(object, propertyDesc.ivar,
                               propertyDesc.shouldCopy ? [parameter copy] : parameter);
            } else
                memcpy(((__bridge void *)object) + ivar_getOffset(propertyDesc.ivar),
                       aArgs[i], propertyDesc.size);
        }
    }
    if([object respondsToSelector:@selector(awakeFromInit)])
        [object awakeFromInit];
    *aoRet = object;
}


#pragma mark - FFI & Type wrangling

static ffi_closure *_ai_ffi_allocClosure(void ** const codePtr)
{
    ffi_closure *closure = (ffi_closure *)mmap(NULL, sizeof(ffi_closure), PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if(closure == (void *)-1) {
        perror("mmap");
        return NULL;
    }
    *codePtr = closure;
    return closure;
}

static ffi_status _ai_ffi_prepareClosure(ffi_closure * const closure, ffi_cif * const cif,
                                         void (*fun)(ffi_cif*,void*,void**,void*),
                                         void * const user_data, void * const codeloc)
{
    ffi_status status = ffi_prep_closure(closure, cif, fun, user_data);
    if(status != FFI_OK)
        return status;
    if(mprotect(closure, sizeof(closure), PROT_READ | PROT_EXEC) == -1)
        return (ffi_status)1;
    return FFI_OK;
}

BOOL _ai_type_is_scalar(const char * const aType)
{
    return !(*aType == _C_STRUCT_B || *aType == _C_UNION_B || *aType == _C_ARY_B);
}

ffi_type *_ai_encodingToFFIType(const char *aEncoding)
{
    if(_ai_type_is_scalar(aEncoding))
        return _ai_scalarTypeToFFIType(aEncoding);
    else if(*aEncoding == _C_STRUCT_B || *aEncoding ==_C_ARY_B) {
        BOOL const isArray = *aEncoding ==_C_ARY_B;

        ffi_type * const type =  malloc(sizeof(ffi_type));
        type->type = FFI_TYPE_STRUCT;
        type->size = type->alignment= 0;
        
        int numFields = 0;
        const char *fieldEncoding;
        if(isArray) {
            ++aEncoding; // Skip past the '['
            assert(isdigit(*aEncoding));
            numFields = atoi(aEncoding);
            // Move on to the enclosed type
            while(isdigit(*aEncoding)) ++aEncoding;
            fieldEncoding = aEncoding;
        } else { // Is struct
            fieldEncoding = strstr(aEncoding, "=") + 1;
            if(*fieldEncoding != _C_STRUCT_E) {
                const char *currField = fieldEncoding;
                do {
                    ++numFields;
                } while((currField = NSGetSizeAndAlignment(currField, NULL, NULL)) && *currField != _C_STRUCT_E);
            }
        }
        assert(numFields > 0);
        type->elements = (ffi_type **)malloc(sizeof(ffi_type*) * numFields + 1);
        
        if(isArray) {
            ffi_type * const fieldType = _ai_encodingToFFIType(fieldEncoding);
            assert(fieldType);
            for(int i = 0; i < numFields; i++) {
                type->elements[i] = fieldType;
            }
        } else {
            for(int i = 0; i < numFields; i++) {
                ffi_type * const fieldType = _ai_encodingToFFIType(fieldEncoding);
                assert(fieldType);
                type->elements[i] = fieldType;
                fieldEncoding = NSGetSizeAndAlignment(fieldEncoding, NULL, NULL);
            }
        }
        
        type->elements[numFields] = NULL;
        return type;
    }    
    else if(*aEncoding == _C_UNION_B) {
        // For unions we just return the ffi type for the first element in the union
        // TODO: this should use the largest type 
        const char *fieldEncoding = strstr(aEncoding, "=") + 1;
        return _ai_encodingToFFIType(fieldEncoding);
    }
    else {
        [NSException raise:NSInternalInconsistencyException
                    format:@"Unhandled type encoding %s", aEncoding];
        return NULL;
    }
}

ffi_type *_ai_scalarTypeToFFIType(const char * const aType)
{
    switch(*aType) {
        case _C_ID:
        case _C_CLASS:
        case _C_SEL:
        case _C_PTR:
        case _C_CHARPTR:  return &ffi_type_pointer;
        case _C_DBL:      return &ffi_type_double;
        case _C_FLT:      return &ffi_type_float;
        case _C_INT:      return &ffi_type_sint;
        case _C_SHT:      return &ffi_type_sshort;
        case _C_CHR:      return &ffi_type_sint8;
        case _C_BOOL:     return &ffi_type_uchar;
        case _C_LNG:      return &ffi_type_slong;
        case _C_LNG_LNG:  return &ffi_type_sint64;
        case _C_UINT:     return &ffi_type_uint;
        case _C_USHT:     return &ffi_type_ushort;
        case _C_UCHR:     return &ffi_type_uchar;
        case _C_ULNG:     return &ffi_type_ulong;
        case _C_ULNG_LNG: return &ffi_type_uint64;
        case _C_VOID:     return &ffi_type_void;
        default:
            [NSException raise:NSGenericException
                        format:@"Unsupported scalar type %c!", *aType];
            return NULL;
    }
}


@implementation NSValue (AutomaticInitializers)

+ (NSValue *)ai_valueWithBytes:(const void * const )aBytes
                       objCType:(const char * const )aType
{
    NSParameterAssert(aType && aBytes);
    switch(*aType) {
        case _C_DBL:      return @(*(double *)aBytes);
        case _C_FLT:      return @(*(float *)aBytes);
        case _C_INT:      return @(*(int *)aBytes);
        case _C_SHT:      return @(*(short *)aBytes);
        case _C_CHR:      return @(*(char *)aBytes);
        case _C_BOOL:     return @(*(BOOL *)aBytes);
        case _C_LNG:      return @(*(long *)aBytes);
        case _C_LNG_LNG:  return @(*(long long *)aBytes);
        case _C_UINT:     return @(*(unsigned int *)aBytes);
        case _C_USHT:     return @(*(unsigned short *)aBytes);
        case _C_UCHR:     return @(*(unsigned char *)aBytes);
        case _C_ULNG:     return @(*(unsigned long *)aBytes);
        case _C_ULNG_LNG: return @(*(unsigned long long *)aBytes);
        default:
            return [self valueWithBytes:aBytes objCType:aType];
    }
}

@end
