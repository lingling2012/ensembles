//
//  CDEAsynchronousTaskQueue.m
//  Ensembles
//
//  Created by Drew McCormack on 4/13/13.
//  Copyright (c) 2013 Drew McCormack. All rights reserved.
//

#import "CDEAsynchronousTaskQueue.h"

@implementation CDEAsynchronousTaskQueue {
    NSArray *tasks;
    NSEnumerator *taskEnumerator;
    CDECompletionBlock completion;
    CDETaskQueueTerminationPolicy terminationPolicy;
    NSMutableArray *errors;
    BOOL isExecuting, isFinished;
}

- (instancetype)initWithTasks:(NSArray *)newTasks terminationPolicy:(CDETaskQueueTerminationPolicy)policy completion:(CDECompletionBlock)newCompletion
{
    self = [super init];
    if (self) {
        errors = [NSMutableArray array];
        terminationPolicy = policy;
        tasks = [newTasks copy];
        completion = [newCompletion copy];
    }
    return self;
}

- (instancetype)initWithTasks:(NSArray *)newTasks completion:(CDECompletionBlock)newCompletion
{
    return [self initWithTasks:newTasks terminationPolicy:CDETaskQueueTerminationPolicyStopOnError completion:newCompletion];
}

- (instancetype)initWithTask:(CDEAsynchronousTaskBlock)task repeatCount:(NSUInteger)count terminationPolicy:(CDETaskQueueTerminationPolicy)policy completion:(CDECompletionBlock)newCompletion
{
    NSMutableArray *newTasks = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        [newTasks addObject:[task copy]];
    }
    return [self initWithTasks:newTasks terminationPolicy:policy completion:newCompletion];
}

- (void)start
{
    @synchronized (self) {
        [self willChangeValueForKey:@"isFinished"];
        [self willChangeValueForKey:@"isExecuting"];
        isFinished = NO;
        isExecuting = YES;
        [self didChangeValueForKey:@"isExecuting"];
        [self didChangeValueForKey:@"isFinished"];
    }
    
    taskEnumerator = [tasks objectEnumerator];
    [self performSelector:@selector(startNextTask) withObject:nil afterDelay:0.0];
    
    while (!self.isFinished) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate distantFuture]];
}

- (NSError *)combineErrors
{
    if (errors.count == 0)
        return nil;
    else if (errors.count == 1)
        return errors.lastObject;
    else {
        NSError *multipleErrorsError = [NSError errorWithDomain:CDEErrorDomain code:CDEErrorCodeMultipleErrors userInfo:@{@"errors": [errors copy]}];
        return multipleErrorsError;
    }
}

- (void)startNextTask
{
    @autoreleasepool {
        if (self.isCancelled) {
            [self finish];
            return;
        }
        
        // We use delayed performs in some calls, because this method can be invoked from a callback block
        // and we don't want to have the block released when it is on the stack.
        // So we let the stack unwind first.
        CDEAsynchronousTaskBlock block = [taskEnumerator nextObject];
        if (block) {
            CDEAsynchronousTaskCallbackBlock next = [^(NSError *error, BOOL stop) {
                BOOL shouldStop = NO;
                if (error && terminationPolicy == CDETaskQueueTerminationPolicyStopOnError) shouldStop = YES;
                if (!error && terminationPolicy == CDETaskQueueTerminationPolicyStopOnSuccess) shouldStop = YES;
                [errors addObject:(error ? : [NSNull null])];
                if (stop) shouldStop = YES;
                if (shouldStop) {
                    [self performSelector:@selector(finish) withObject:nil afterDelay:0.0];
                }
                else
                    [self performSelector:@selector(startNextTask) withObject:nil afterDelay:0.0];
            } copy];
            block(next);
        }
        else {
            [self performSelector:@selector(finish) withObject:nil afterDelay:0.0];
        }
    }
}

- (void)finish
{
    NSError *error = nil;
    NSError *lastError = errors.lastObject;
    if ((id)lastError == [NSNull null]) lastError = nil;

    if (self.isCancelled) {
        error = [NSError errorWithDomain:CDEErrorDomain code:CDEErrorCodeCancelled userInfo:nil];
    }
    else {
        switch (terminationPolicy) {
            case CDETaskQueueTerminationPolicyStopOnError:
                error = lastError;
                break;
                
            case CDETaskQueueTerminationPolicyStopOnSuccess:
                error = lastError ? [self combineErrors] : nil; // If succeeded, don't return any errors
                break;
                
            case CDETaskQueueTerminationPolicyCompleteAll:
                {
                    NSMutableArray *nonNull = [errors mutableCopy];
                    [nonNull removeObject:[NSNull null]];
                    error = nonNull.count > 0 ? [self combineErrors] : nil;
                }
                break;
                
            default:
                @throw [NSException exceptionWithName:CDEException reason:@"Invalid policy" userInfo:nil];
                break;
        }
    }
    
    if (completion) completion(error);
    
    @synchronized (self) {
        [self willChangeValueForKey:@"isFinished"];
        [self willChangeValueForKey:@"isExecuting"];
        isFinished = YES;
        isExecuting = NO;
        [self didChangeValueForKey:@"isExecuting"];
        [self didChangeValueForKey:@"isFinished"];
    }
    
    tasks = nil;
    completion = NULL;
}

- (BOOL)isConcurrent
{
    return YES;
}

- (BOOL)isExecuting
{
    @synchronized (self) {
        return isExecuting;
    }
}

- (BOOL)isFinished
{
    @synchronized (self) {
        return isFinished;
    }
}

@end
