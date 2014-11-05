angular
.module('CreateTaskApp', ['InSTEDD.Hub.Browser', 'InSTEDD.Hub.SourceBox', 'InSTEDD.Hub.TargetBox'])

.controller 'CreateTaskCtrl', ($scope, $http) ->

  # hacks for testing. ONA Connec
  $scope.event = {reflect_url: "http://local.instedd.org:3000/connectors/3/reflect/forms/10464/$events/new_data"}
  # $scope.event = {reflect_url: "http://local.instedd.org:3000/connectors/5/reflect/indices/mbuilder_application_1/types/05f222da-48f3-4a8b-8123-fce18e457fb7/$actions/insert"}
  $scope.action = {reflect_url:"http://local.instedd.org:3000/connectors/5/reflect/indices/mbuilder_application_1/types/05f222da-48f3-4a8b-8123-fce18e457fb7/$actions/insert"}

  $scope.$watch 'event', (event) ->
    unless event?
      $scope.event_reflect = null
      return

    $http.get(event.reflect_url).success (data) ->
      $scope.event_reflect = data

  $scope.$watch 'action', (action) ->
    unless action?
      $scope.action_reflect = null
      return

    $http.get(action.reflect_url).success (data) ->
      $scope.action_reflect = data

  $scope.$watch 'action_reflect', (action_reflect) ->
    unless action_reflect?
      $scope.mapping = null
      return

    $scope.mapping = default_mapping({type: {kind: 'struct', members: action_reflect.args}})


  default_mapping = (object) ->
    if object.type?.kind == 'struct'
      res = {
        type: "struct"
        members: { }
      }

      for key, value of object.type.members
        res.members[key] = default_mapping(value)

      res
    else
      {
        type: "literal"
        value: null
      }
