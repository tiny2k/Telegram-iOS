#import "SSignal+Multicast.h"

#import <os/lock.h>
#import "SBag.h"
#import "SBlockDisposable.h"

typedef enum {
    SSignalMulticastStateReady,
    SSignalMulticastStateStarted,
    SSignalMulticastStateCompleted
} SSignalMulticastState;

@interface SSignalMulticastSubscribers : NSObject
{
    os_unfair_lock _lock;
    SBag *_subscribers;
    SSignalMulticastState _state;
    id<SDisposable> _disposable;
}

@end

@implementation SSignalMulticastSubscribers

- (instancetype)init
{
    self = [super init];
    if (self != nil)
    {
        _subscribers = [[SBag alloc] init];
    }
    return self;
}

- (void)setDisposable:(id<SDisposable>)disposable
{
    [_disposable dispose];
    _disposable = disposable;
}

- (id<SDisposable>)addSubscriber:(SSubscriber *)subscriber start:(bool *)start
{
    os_unfair_lock_lock(&_lock);
    NSInteger index = [_subscribers addItem:subscriber];
    switch (_state) {
        case SSignalMulticastStateReady:
            *start = true;
            _state = SSignalMulticastStateStarted;
            break;
        default:
            break;
    }
    os_unfair_lock_unlock(&_lock);
    
    return [[SBlockDisposable alloc] initWithBlock:^
    {
        [self remove:index];
    }];
}

- (void)remove:(NSInteger)index
{
    id<SDisposable> currentDisposable = nil;
    
    os_unfair_lock_lock(&_lock);
    [_subscribers removeItem:index];
    switch (_state) {
        case SSignalMulticastStateStarted:
            if ([_subscribers isEmpty])
            {
                currentDisposable = _disposable;
                _disposable = nil;
            }
            break;
        default:
            break;
    }
    os_unfair_lock_unlock(&_lock);
    
    [currentDisposable dispose];
}

- (void)notifyNext:(id)next
{
    NSArray *currentSubscribers = nil;
    os_unfair_lock_lock(&_lock);
    currentSubscribers = [_subscribers copyItems];
    os_unfair_lock_unlock(&_lock);
    
    for (SSubscriber *subscriber in currentSubscribers)
    {
        [subscriber putNext:next];
    }
}

- (void)notifyError:(id)error
{
    NSArray *currentSubscribers = nil;
    os_unfair_lock_lock(&_lock);
    currentSubscribers = [_subscribers copyItems];
    _state = SSignalMulticastStateCompleted;
    os_unfair_lock_unlock(&_lock);
    
    for (SSubscriber *subscriber in currentSubscribers)
    {
        [subscriber putError:error];
    }
}

- (void)notifyCompleted
{
    NSArray *currentSubscribers = nil;
    os_unfair_lock_lock(&_lock);
    currentSubscribers = [_subscribers copyItems];
    _state = SSignalMulticastStateCompleted;
    os_unfair_lock_unlock(&_lock);
    
    for (SSubscriber *subscriber in currentSubscribers)
    {
        [subscriber putCompletion];
    }
}

@end

@implementation SSignal (Multicast)

- (SSignal *)multicast
{
    SSignalMulticastSubscribers *subscribers = [[SSignalMulticastSubscribers alloc] init];
    return [[SSignal alloc] initWithGenerator:^id<SDisposable> (SSubscriber *subscriber)
    {
        bool start = false;
        id<SDisposable> currentDisposable = [subscribers addSubscriber:subscriber start:&start];
        if (start)
        {
            id<SDisposable> disposable = [self startWithNext:^(id next)
            {
                [subscribers notifyNext:next];
            } error:^(id error)
            {
                [subscribers notifyError:error];
            } completed:^
            {
                [subscribers notifyCompleted];
            }];
            
            [subscribers setDisposable:[[SBlockDisposable alloc] initWithBlock:^
            {
                [disposable dispose];
            }]];
        }
        
        return currentDisposable;
    }];
}

@end
