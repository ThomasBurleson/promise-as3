////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2013 CodeCatalyst, LLC - http://www.codecatalyst.com/
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
////////////////////////////////////////////////////////////////////////////////

package com.codecatalyst.promise.inteceptors
{

    import flash.events.Event;
    import flash.events.IEventDispatcher;
    import flash.utils.getQualifiedClassName;

    /**
     * EventInterceptor is class that wraps event dispatchers to listen to 1...n events
     * and extract data when those events occur. The EventInterceptor is configured in 2-phases:
     *
     *   1) new EventInterceptor() or ::intercept() - to define result and fault events and data keys
     *   2) addCallbacks() - to register callback result/fault handlers
     *
     * Only when addCallbacks() is invoked are the listeners attached.
     * When the result or fault event is detected, the callback is triggered/notified and the listeners
     * are all removed.
     *
     * Usage example:
     * <code>
     *
     *     // Authenticator is an event dispatcher with two (2) custom
     *     // response events: AUTHENTICATED and NOT_ALLOWED
     *
     *     var authenticator : Authenticator    = new Authenticator;

     *         authenticator.loginUser( userName, password );

     *     var interceptor   : EventIntercepter = new EventIntercepter( authenticator );
     *
     *         interceptor.intercept(
     *                       { type: AuthenticationEvent.AUTHENTICATED, key: 'session' },
     *                       { type: AuthenticationEvent.NOT_ALLOWED,   key: 'details' }
     *                    )
     *                    .addCallbacks (
     *                       function onLoginOK( session:Object ):void {
     *                           // Save the session information and continue login process
     *                       },
     *
     *                       function onLoginFailed( fault:Object  ):void {
     *                          // Report the login failure and request another attempt
     *                       }
     *                    );
     *
     *</code>
     *
     * This class is actually intended to be used with Promise.all() and the globally registered DispatcherAdapter.
     * The resulting code usage is significantly more intuitive and useful:
     *
     * <code>
     *
     *     // The EventIntercepter listens for specific events from authenticator
     *     // and extracts data based on the specified keys; e.g. `session` and `details`
     *
     *     function loginUser( userName:String, password:String ):Promise
     *     {
     *          var authenticator : Authenticator = new Authenticator;
     *
     *              authenticator.loginUser( userName, password );
     *
     *         return Promise.all( new EventIntercepter (
     *                  authenticator,
     *                  AuthenticationEvent.AUTHENTICATED, 'session',
     *                  AuthenticationEvent.NOT_ALLOWED,   'details'
     *         ));
     *     }
     *
     *
     *     loginUser(
     *          'ThomasB',
     *          "superSecretPassword"
     *     )
     *     .then(
     *
     *         function onLoginOK( session:Object ):void {
     *             // Save the session information and continue login process
     *         },
     *
     *         function onLoginFailed( fault:Object  ):void {
     *            // Report the login failure and request another attempt
     *         }
     *
     *     );
     *
     *</code>
     *
     */
    public class EventIntercepter
    {
        /**
         *  Accessor used by DispatcherAdapter to add private callbacks
         *  to resolve/reject Deferreds when future dispatcher result or fault activity occurs
         */
        public function get addCallbacks( ) : Function
        {
            return _addCallbackFunc;
        }

        // *************************************************************
        // Constructor
        // *************************************************************

        /**
         * Constructor to intercept specific events from a dispatcher
         * and route to a Promise
         *
         * @see DispatcherAdapter
         */
        public function EventIntercepter (
            source    : IEventDispatcher,
            resultType: String = null, resultKey: String = null,
            faultType : String = null, faultKey : String = null )
        {
            _source           = source;

            intercept (
                ( resultType && resultKey ) ? { type : resultType,     key : resultKey } : null,
                ( faultType  && faultKey  ) ? { type : faultType,      key : faultKey}   : null
            )

        }

        // *************************************************************
        // Public Methods
        // *************************************************************

        /**
         * Use the specified result events and fault events (expected to be dispatched from `_source`)
         * and add listeners. Build addCallBacks() function that allows external users to submit
         * result and fault callback handlers to these events.
         *
         * @param resultEvents  Object or Array of { type:"", key:""} name/value pairs
         * @param faultEvents   Object or Array of { type:"", key:""} name/value pairs
         *
         * @return EventIntercepter instance (useful for chaining)
         */
        public function intercept( resultEvents:Object, faultEvents:Object=null ): EventIntercepter
        {
            release();
            _addCallbackFunc = prepareAddCallbacks ( resultEvents, faultEvents );

            return this;
        }

        /**
         * Clean existing callbacks and listeners
         */
        public function release() : void
        {
            if ( _addCallbackFunc != null )
            {
                _addCallbackFunc( null );
                _addCallbackFunc = null;
            }
        }


        // *************************************************************
        // Protected Methods
        // *************************************************************

        /**
         * Partial application of result/fault information that will be used
         * to establish listeners WHEN result/fault callbacks are registered.
         *
         * This method prepares a Function that can be later used to register the callbacks.
         *
         * @param resultEvents  Object/Array of { type : <eventType>, key : <dataKey> } for result events
         * @param faultEvents   Object/Array of { type : <eventType>, key : <dataKey> } for fault events
         *
         * @return Function that can be later used to register the callbacks.
         */
        protected function prepareAddCallbacks( resultEvents:Object, faultEvents:Object=null ): Function
        {
            var it : Object;

            // Validate arguments...
            if ( resultEvents && !(resultEvents is Array )) resultEvents = [ resultEvents ];
            if ( faultEvents  && !(faultEvents  is Array )) faultEvents  = [ faultEvents ];

            resultEvents ||= [ ];
            faultEvents  ||= [ ];

                /**
                 * Partial application with result/fault type and keys already captured...
                 */
                function registerHandlers( resultHandlerFunc:Function, faultHandleFunc:Function=null, scope:Object=null ):void
                {
                    if ( resultHandlerFunc == null )
                    {
                        releaseListeners();
                        return;
                    }

                        /**
                         * Based on the eventType, extract the data using the registered event `key`
                         * Array items in the array are expected to be Hashmaps of `type, key` pairs
                         * e.g.
                         *      {
                         *          type : "loggedIn"
                         *          key  : "session"
                         *      }
                         *
                         * @param event
                         * @return
                         */
                        function extractDataFrom( event:Event ):*
                        {
                            var all : Array = [ ].concat( resultEvents ).concat( faultEvents );

                            for each ( it in all )
                            {
                                if ( it.type == event.type )
                                    return it.key == "event" ? event : event[ it.key ];
                            }

                            return null;
                        }

                        /**
                         *  Clear connections to responder (handler proxy)
                         */
                        function releaseListeners():void
                        {
                            for each ( it in resultEvents )   _source.removeEventListener(it.type,  onResult);
                            for each ( it in faultEvents )    _source.removeEventListener(it.type,  onFault);
                        }

                        /**
                         *  Extract `resultKey` data and deliver to originating result Handler
                         */
                        function onResult(event:Event):void
                        {
                            try {

                                if ( resultHandlerFunc != null )
                                    resultHandlerFunc.call(scope, extractDataFrom( event ) );
                            }
                            catch( e:Error ) {
                                // Attempt to specify where the error occurred...

                                e.message = "Error in "                    +
                                            getQualifiedClassName( scope ) +
                                            " during resultHandlerFunc.call(): " +
                                            String(e.message)

                                throw( e );
                            }
                            finally {
                                releaseListeners();
                            }
                        }

                        /**
                         *  Extract `faultKey` data and deliver to originating fault Handler
                         */
                        function onFault(event:Event):void
                        {
                            try {

                                if ( faultHandleFunc != null )
                                    faultHandleFunc.call(scope, extractDataFrom( event ) );

                            } finally { releaseListeners(); }
                        }


                    // Add listeners so responders are notified FIRST

                    for each (it in resultEvents) _source.addEventListener(it.type,  onResult, false, 10 );
                    for each (it in faultEvents)  _source.addEventListener(it.type,  onFault,  false, 10 );
                }

            return registerHandlers;
        }

        // *************************************************************
        // Protected Properties
        // *************************************************************

        protected var _source           : IEventDispatcher;
        protected var _addCallbackFunc : Function;
    }
}
