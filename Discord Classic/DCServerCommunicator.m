//
//  DCServerCommunicator.m
//  Discord Classic
//
//  Created by Julian Triveri on 3/4/18.
//  Copyright (c) 2018 Julian Triveri. All rights reserved.
//

#import "DCServerCommunicator.h"
#import "DCGuild.h"
#import "DCChannel.h"
#import "DCTools.h"

@interface DCServerCommunicator()
@property bool didRecieveHeartbeatResponse;
@property bool shouldResume;
@property bool heartbeatDefined;

@property bool identifyCooldown;

@property int sequenceNumber;
@property NSString* sessionId;

@property NSString* snowflake;

@property NSTimer* cooldownTimer;
@property UIAlertView* alertView;
@end


@implementation DCServerCommunicator

+ (DCServerCommunicator *)sharedInstance {
	static DCServerCommunicator *sharedInstance = nil;
	
	if (sharedInstance == nil) {
		//Initialize if a sharedInstance does not yet exist
		sharedInstance = DCServerCommunicator.new;
		sharedInstance.identifyCooldown = true;
	}
	
	return sharedInstance;
}


- (void)startCommunicator{
	
	//Init and grab user settings
	self.didRecieveHeartbeatResponse = true;
	self.token = [NSUserDefaults.standardUserDefaults stringForKey:@"token"];
	bool permissionCalculationEnabled = [NSUserDefaults.standardUserDefaults boolForKey:@"perm calc"];
	
	self.gatewayURL = @"wss://gateway.discord.gg/?encoding=json&v=6";
	
	//To prevent retain cycle
	__weak typeof(self) weakSelf = self;
	
	if(self.token!=nil){
		
		//Establish websocket connection with Discord
		NSURL *websocketUrl = [NSURL URLWithString:self.gatewayURL];
		self.websocket = [WSWebSocket.alloc initWithURL:websocketUrl protocols:nil];
		
		[self.websocket setTextCallback:^(NSString *responseString) {
			
			//Parse JSON to a dictionary
			NSDictionary *parsedJsonResponse = [DCTools parseJSON:responseString];
			
			//Data values for easy access
			int op = [[parsedJsonResponse valueForKey:@"op"] integerValue];
			NSDictionary* d = [parsedJsonResponse valueForKey:@"d"];
			
			NSLog(@"Got op code %i", op);
			
			//revcieved HELLO event
			if(op == 10){
				
				if(self.shouldResume){
					
					NSLog(@"Sending Resume with sequence number %i, session ID %@", self.sequenceNumber, self.sessionId);
					
					//RESUME
					[weakSelf sendJSON:@{
					 @"op":@6,
					 @"d":@{
					 @"token":self.token,
					 @"session_id":self.sessionId,
					 @"seq":@(self.sequenceNumber),
					 }
					 }];
					
					self.shouldResume = false;
					
				}else{
					
					NSLog(@"Sending Identify");
					
					//IDENTIFY
					[weakSelf sendJSON:@{
					 @"op":@2,
					 @"d":@{
					 @"token":self.token,
					 @"properties":@{ @"$browser" : @"peble" },
					 @"large_threshold":@"50",
					 }
					 }];
					
					//Disable ability to identify until reenabled 5 seconds later.
					//API only allows once identify every 5 seconds
					self.identifyCooldown = false;
					
					int heartbeatInterval = [[d valueForKey:@"heartbeat_interval"] intValue];
					
					dispatch_async(dispatch_get_main_queue(), ^{
						
						static dispatch_once_t once;
						dispatch_once(&once, ^ {
							
							//Begin heartbeat cycle if not already begun
							[NSTimer scheduledTimerWithTimeInterval:heartbeatInterval/1000
																							 target:weakSelf
																						 selector:@selector(sendHeartbeat:)
																						 userInfo:nil
																							repeats:YES];
							
							//Reenable ability to identify in 5 seconds
							self.cooldownTimer = [NSTimer scheduledTimerWithTimeInterval:5
																																		target:weakSelf
																																	selector:@selector(refreshIdentifyCooldown:)
																																	userInfo:nil
																																	 repeats:NO];
						});
					});
					
				}
			}
			
			
			//Misc Event
			if(op == 0){
				
				//Get event type and sequence number
				NSString* t = [parsedJsonResponse valueForKey:@"t"];
				self.sequenceNumber = [[parsedJsonResponse valueForKey:@"s"] integerValue];
				
				NSLog(@"Got event %@ with sequence number %i", t, self.sequenceNumber);
				
				//recieved READY
				if([t isEqualToString:@"READY"]){
					
					//Grab session id (used for RESUME) and user id
					self.sessionId = [d valueForKey:@"session_id"];
					self.snowflake = [d valueForKeyPath:@"user.id"];
					
					//array of all guilds the user is a member of
					self.guilds = NSMutableArray.new;
					//all channels with their ids as keys
					self.channels = NSMutableDictionary.new;
					
					NSMutableDictionary* userChannelSettings = NSMutableDictionary.new;
					for(NSDictionary* guildSettings in [d valueForKey:@"user_guild_settings"])
						for(NSDictionary* channelSetting in [guildSettings objectForKey:@"channel_overrides"])
							[userChannelSettings setValue:@((bool)[channelSetting valueForKey:@"muted"]) forKey:[channelSetting valueForKey:@"channel_id"]];
					
					//Get user DMs and DM groups
					//The user's DMs are treated like a guild, where the channels are different DM/groups
					DCGuild* privateGuild = DCGuild.new;
					privateGuild.name = @"Direct Messages";
					privateGuild.channels = NSMutableArray.new;
					
					for(NSDictionary* privateChannel in [d valueForKey:@"private_channels"]){
						
						DCChannel* newChannel = DCChannel.new;
						newChannel.snowflake = [privateChannel valueForKey:@"id"];
						newChannel.lastMessageId = [privateChannel valueForKey:@"last_message_id"];
						newChannel.parentGuild = privateGuild;
						newChannel.type = 1;
						
						NSString* privateChannelName = [privateChannel valueForKey:@"name"];
						
						//Some private channels dont have names, check if nil
						if(privateChannelName && privateChannelName != (id)NSNull.null){
							newChannel.name = privateChannelName;
						}else{
							//If no name, create a name from channel members
							NSMutableString* fullChannelName = [@"" mutableCopy];
							
							NSArray* privateChannelMembers = [privateChannel valueForKey:@"recipients"];
							for(NSDictionary* privateChannelMember in privateChannelMembers){
								//add comma between member names
								if([privateChannelMembers indexOfObject:privateChannelMember] != 0)
									[fullChannelName appendString:@", @"];
								
								NSString* memberName = [privateChannelMember valueForKey:@"username"];
								[fullChannelName appendString:memberName];
								
								newChannel.name = fullChannelName;
							}
						}
						
						[privateGuild.channels addObject:newChannel];
						[self.channels setObject:newChannel forKey:newChannel.snowflake];
					}
					[self.guilds addObject:privateGuild];
					
					
					//Get servers (guilds) the user is a member of
					for(NSDictionary* jsonGuild in [d valueForKey:@"guilds"]){
						
						NSMutableArray* userRoles;
						
						if(permissionCalculationEnabled){
							//Get roles of the current user
							for(NSDictionary* member in [jsonGuild objectForKey:@"members"])
								if([[member valueForKeyPath:@"user.id"] isEqualToString:self.snowflake])
									userRoles = [[member valueForKey:@"roles"] mutableCopy];
							
							//Get @everyone role
							for(NSDictionary* guildRole in [jsonGuild objectForKey:@"roles"])
								if([[guildRole valueForKey:@"name"] isEqualToString:@"@everyone"])
									[userRoles addObject:[guildRole valueForKey:@"id"]];
						}
						
						DCGuild* newGuild = DCGuild.new;
						newGuild.name = [jsonGuild valueForKey:@"name"];
						newGuild.snowflake = [jsonGuild valueForKey:@"id"];
						newGuild.channels = NSMutableArray.new;
						
						NSString* iconURL = [NSString stringWithFormat:@"https://cdn.discordapp.com/icons/%@/%@",
																 newGuild.snowflake, [jsonGuild valueForKey:@"icon"]];
						
						[DCTools processImageDataWithURLString:iconURL andBlock:^(NSData *imageData) {
							newGuild.icon = [UIImage imageWithData:imageData];
							
							dispatch_async(dispatch_get_main_queue(), ^{
								[NSNotificationCenter.defaultCenter postNotificationName:@"RELOAD GUILD LIST" object:weakSelf];
							});
							
						}];
						
						for(NSDictionary* jsonChannel in [jsonGuild valueForKey:@"channels"]){
							
							//Make sure jsonChannel is a text cannel
							//we dont want to include voice channels in the text channel list
							if([jsonChannel valueForKey:@"type"] == @0){
								
								//Allow code is used to calculate the permission hirearchy.
								/*
								 0 - No overwrites. Channel should be created
								 
								 1 - Hidden by role. Channel should not be created unless another role contradicts (code 2)
								 2 - Shown by role. Channel should be created unless hidden by member overwrite (code 3)
								 
								 3 - Hidden by member. Channel should not be created
								 4 - Shown by member. Channel should be created
								 
								 3 & 4 are mutually exclusive
								 */
								int allowCode = 0;
								
								if(permissionCalculationEnabled){
									
									//Calculate permissions
									for(NSDictionary* permission in [jsonChannel objectForKey:@"permission_overwrites"]){
										
										
										
										//Type of permission can either be role or member
										NSString* type = [permission valueForKey:@"type"];
										
										if([type isEqualToString:@"role"]){
											
											//Check if this channel dictates permissions over any roles the user has
											if([userRoles containsObject:[permission valueForKey:@"id"]]){
												int deny = [[permission valueForKey:@"deny"] intValue];
												int allow = [[permission valueForKey:@"allow"] intValue];
												
												if((deny & 1024) == 1024 && allowCode < 1)
													allowCode = 1;
												
												if(((allow & 1024) == 1024) && allowCode < 2)
													allowCode = 2;
											}
										}
										
										
										if([type isEqualToString:@"member"]){
											
											//Check if
											NSString* memberId = [permission valueForKey:@"id"];
											if([memberId isEqualToString:self.snowflake]){
												int deny = [[permission valueForKey:@"deny"] intValue];
												int allow = [[permission valueForKey:@"allow"] intValue];
												
												if((deny & 1024) == 1024 && allowCode < 3)
													allowCode = 3;
												
												if((allow & 1024) == 1024){
													allowCode = 4;
													break;
												}
											}
										}
									}
								}
								
								if(allowCode == 0 || allowCode == 2 || allowCode == 4){
									DCChannel* newChannel = DCChannel.new;
									
									newChannel.snowflake = [jsonChannel valueForKey:@"id"];
									newChannel.name = [jsonChannel valueForKey:@"name"];
									newChannel.lastMessageId = [jsonChannel valueForKey:@"last_message_id"];
									newChannel.parentGuild = newGuild;
									newChannel.type = 0;
									
									if([userChannelSettings objectForKey:newChannel.snowflake]){
										newChannel.muted = true;
									}
									
									//check if channel is muted
									
									[newGuild.channels addObject:newChannel];
									[self.channels setObject:newChannel forKey:newChannel.snowflake];
								}
							}
						}
						
						[self.guilds addObject:newGuild];
					}
					
					
					//Read states are recieved in READY payload
					//they give a channel ID and the ID of the last read message in that channel
					NSArray* readstatesArray = [d valueForKey:@"read_state"];
					
					for(NSDictionary* readstate in readstatesArray){
						
						NSString* readstateChannelId = [readstate valueForKey:@"id"];
						NSString* readstateMessageId = [readstate valueForKey:@"last_message_id"];
						
						//Get the channel with the ID of readStateChannelId
						DCChannel* channelOfReadstate = [self.channels objectForKey:readstateChannelId];
						
						channelOfReadstate.lastReadMessageId = readstateMessageId;
						[channelOfReadstate checkIfRead];
					}
					
					dispatch_async(dispatch_get_main_queue(), ^{
						[NSNotificationCenter.defaultCenter postNotificationName:@"READY" object:weakSelf];
						
						//Dismiss the 'reconnecting' dialogue box
						[self.alertView dismissWithClickedButtonIndex:0 animated:YES];
					});
				}
				
				
				if([t isEqualToString:@"MESSAGE_ACK"])
					[NSNotificationCenter.defaultCenter postNotificationName:@"MESSAGE ACK" object:weakSelf];
				
				
				if([t isEqualToString:@"MESSAGE_CREATE"]){
					
					NSString* channelIdOfMessage = [d objectForKey:@"channel_id"];
					NSString* messageId = [d objectForKey:@"id"];
					
					//Check if a channel is currently being viewed
					//and if so, if that channel is the same the message was sent in
					if(self.selectedChannel != nil && [channelIdOfMessage isEqualToString:self.selectedChannel.snowflake]){
						
						dispatch_async(dispatch_get_main_queue(), ^{
							//Send notification with the new message
							//will be recieved by DCChatViewController
							[NSNotificationCenter.defaultCenter postNotificationName:@"MESSAGE CREATE" object:weakSelf userInfo:d];
						});
						
						//Update current channel & read state last message
						[self.selectedChannel setLastMessageId:messageId];
						
						//Ack message since we are currently viewing this channel
						[weakSelf ackMessage:messageId inChannel:weakSelf.selectedChannel];
					}else{
						DCChannel* channelOfMessage = [self.channels objectForKey:channelIdOfMessage];
						channelOfMessage.lastMessageId = messageId;
						
						[channelOfMessage checkIfRead];
						
						dispatch_async(dispatch_get_main_queue(), ^{
							[NSNotificationCenter.defaultCenter postNotificationName:@"MESSAGE ACK" object:weakSelf];
						});
					}
				}
			}
			
			
			if(op == 11){
				NSLog(@"Got heartbeat response");
				self.didRecieveHeartbeatResponse = true;
			}
			
			if(op == 9)
				dispatch_async(dispatch_get_main_queue(), ^{
					[weakSelf reconnect];
				});
		}];
		
		[self.websocket open];
	}
}


- (void)sendResume{
	self.shouldResume = true;
	[self startCommunicator];
}



- (void)reconnect{
	NSLog(@"Identify cooldown %f",self.cooldownTimer.fireDate.timeIntervalSinceNow);
	
	//Begin new session
	[self.websocket close];
	
	//If an identify cooldown is in effect, wait for the time needed until sending another IDENTIFY
	//if not, send immediately
	if(self.identifyCooldown)
		[self startCommunicator];
	else
		[self performSelector:@selector(startCommunicator)
							 withObject:nil
							 afterDelay:self.cooldownTimer.fireDate.timeIntervalSinceNow];
	
	self.identifyCooldown = false;
	
	//Displau the 'reconnecting' dialogue box
	[self.alertView dismissWithClickedButtonIndex:0 animated:NO];
	self.alertView = [UIAlertView.alloc initWithTitle:@"Reconnecting"
																						message:@"\n"
																					 delegate:self
																	cancelButtonTitle:nil
																	otherButtonTitles:nil];
	
	UIActivityIndicatorView *spinner = [UIActivityIndicatorView.alloc initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
	spinner.center = CGPointMake(139.5, 75.5);
	
	[self.alertView addSubview:spinner];
	[spinner startAnimating];
	
	[self.alertView show];
}


- (void)sendHeartbeat:(NSTimer *)timer{
	//Check that we've recieved a response since the last heartbeat
	if(self.didRecieveHeartbeatResponse){
		[self sendJSON:@{ @"op": @1, @"d": @(self.sequenceNumber)}];
		NSLog(@"Sent heartbeat");
		[self setDidRecieveHeartbeatResponse:false];
	}else{
		//If we didnt get a response in between heartbeats, we've disconnected from the websocket
		//send a RESUME to reconnect
		NSLog(@"Did not get heartbeat response, sending RESUME with sequence %i %@", self.sequenceNumber, self.sessionId);
		[self sendResume];
	}
}

//Once the 5 second identify cooldown is over
- (void)refreshIdentifyCooldown:(NSTimer *)timer{
	self.identifyCooldown = true;
}

- (void)sendJSON:(NSDictionary*)dictionary{
	NSError *writeError = nil;
	
	NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dictionary
																										 options:NSJSONWritingPrettyPrinted
																											 error:&writeError];
	
	NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
	[self.websocket sendText:jsonString];
}


- (NSDictionary*)sendMessage:(NSString*)message inChannel:(DCChannel*)channel{
	
	NSURL* channelURL = [NSURL URLWithString:
											 [NSString stringWithFormat:@"%@%@%@",
												@"https://discordapp.com/api/channels/",
												channel.snowflake,
												@"/messages"]];
	
	NSMutableURLRequest *urlRequest=[NSMutableURLRequest requestWithURL:channelURL
																													cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
																											timeoutInterval:5];
	
	NSString* messageString = [NSString stringWithFormat:@"{\"content\":\"%@\"}", message];
	
	[urlRequest setHTTPBody:[NSData dataWithBytes:[messageString UTF8String] length:[messageString length]]];
	[urlRequest addValue:DCServerCommunicator.sharedInstance.token forHTTPHeaderField:@"Authorization"];
	[urlRequest addValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
	[urlRequest setHTTPMethod:@"POST"];
	
	
	NSError *error = nil;
	NSHTTPURLResponse *responseCode = nil;
	
	NSData *response = [DCTools checkData:[NSURLConnection sendSynchronousRequest:urlRequest
																															returningResponse:&responseCode
																																					error:&error] withError:error];
	
	if(response)
		return [NSJSONSerialization JSONObjectWithData:response options:0 error:&error];
	return nil;
}


- (NSDictionary*)ackMessage:(NSString*)messageId inChannel:(DCChannel*)channel{
	
	if(messageId != (id)NSNull.null){
		channel.lastReadMessageId = messageId;
		
		NSURL* channelURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@%@%@%@",
																							@"https://discordapp.com/api/channels/",
																							channel.snowflake, @"/messages/",
																							messageId,
																							@"/ack"]];
		
		NSMutableURLRequest *urlRequest=[NSMutableURLRequest requestWithURL:channelURL
																														cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
																												timeoutInterval:5];
		
		[urlRequest addValue:DCServerCommunicator.sharedInstance.token forHTTPHeaderField:@"Authorization"];
		[urlRequest addValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
		[urlRequest setHTTPMethod:@"POST"];
		
		
		NSError *error = nil;
		NSHTTPURLResponse *responseCode = nil;
		
		NSData *response = [DCTools checkData:[NSURLConnection sendSynchronousRequest:urlRequest
																																returningResponse:&responseCode
																																						error:&error] withError:error];
		
		if(response)
			return [NSJSONSerialization JSONObjectWithData:response options:0 error:&error];
	}
	return nil;
}

@end
