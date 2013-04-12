require 'active_support'

module Pod
  class Installer
    class UserProjectIntegrator

      # This class is responsible for integrating the library generated by a
      # {TargetDefinition} with its destination project.
      #
      class TargetIntegrator

        # @return [Library] the library that should be integrated.
        #
        attr_reader :library

        # @param  [Library] library @see #target_definition
        #
        def initialize(library)
          @library = library
        end

        # Integrates the user project targets. Only the targets that do **not**
        # already have the Pods library in their frameworks build phase are
        # processed.
        #
        # @return [void]
        #
        def integrate!
          return if targets.empty?
          UI.section(integration_message) do
            add_xcconfig_base_configuration
            add_pods_library
            add_copy_resources_script_phase
            add_check_manifest_lock_script_phase
            save_user_project
          end
        end

        # @return [Array<PBXNativeTarget>] the list of targets that the Pods
        #         lib that need to be integrated.
        #
        # @note   A target is considered integrated if it already references
        #
        def targets
          unless @targets
            target_uuids = library.user_target_uuids
            targets = target_uuids.map do |uuid|
              target = user_project.objects_by_uuid[uuid]
              unless target
                raise Informative, "[Bug] Unable to find the target with " \
                  "the `#{uuid}` UUID for the `#{library}` library"
              end
              target
            end
            non_integrated = targets.reject do |target|
              target.frameworks_build_phase.files.any? do |build_file|
                file_ref = build_file.file_ref
                file_ref &&
                  file_ref.isa == 'PBXFileReference' &&
                  file_ref.display_name == library.product_name
              end
            end
            @targets = non_integrated
          end
          @targets
        end

        # Read the project from the disk to ensure that it is up to date as
        # other TargetIntegrators might have modified it.
        #
        def user_project
          @user_project ||= Xcodeproj::Project.new(library.user_project_path)
        end

        # @return [String] a string representation suitable for debugging.
        #
        def inspect
          "#<#{self.class} for target `#{target_definition.label}'>"
        end

        #---------------------------------------------------------------------#

        # @!group Integration steps

        private

        # Adds the `xcconfig` configurations files generated for the current
        # {TargetDefinition} to the build configurations of the targets that
        # should be integrated.
        #
        # @note   It also checks if any build setting of the build
        #         configurations overrides the `xcconfig` file and warns the
        #         user.
        #
        # @todo   If the xcconfig is already set don't override it and inform
        #         the user.
        #
        # @return [void]
        #
        def add_xcconfig_base_configuration
          xcconfig = user_project.new_file(library.xcconfig_relative_path)
          targets.each do |target|
            check_overridden_build_settings(library.xcconfig, target)
            target.build_configurations.each do |config|
              config.base_configuration_reference = xcconfig
            end
          end
        end

        # Adds a file reference to the library of the {TargetDefinition} and
        # adds it to the frameworks build phase of the targets.
        #
        # @return [void]
        #
        def add_pods_library
          frameworks = user_project.frameworks_group
          pods_library = frameworks.new_static_library(library.label)
          targets.each do |target|
            target.frameworks_build_phase.add_file_reference(pods_library)
          end
        end

        # Adds a shell script build phase responsible to copy the resources
        # generated by the TargetDefinition to the bundle of the product of the
        # targets.
        #
        # @return [void]
        #
        def add_copy_resources_script_phase
          targets.each do |target|
            phase = target.new_shell_script_build_phase('Copy Pods Resources')
            path  = library.copy_resources_script_relative_path
            phase.shell_script = %{"#{path}"\n}
          end
        end

        # Adds a shell script build phase responsible for checking if the Pods
        # locked in the Pods/Manifest.lock file are in sync with the Pods defined
        # in the Podfile.lock.
        #
        # @note   The build phase is appended to the front because to fail
        #         fast.
        #
        # @return [void]
        #
        def add_check_manifest_lock_script_phase
          targets.each do |target|
            phase = target.project.new(Xcodeproj::Project::Object::PBXShellScriptBuildPhase)
            target.build_phases.unshift(phase)
            phase.name = 'Check Pods Manifest.lock'
            phase.shell_script = <<-EOS.strip_heredoc
              diff "${PODS_ROOT}/../Podfile.lock" "${PODS_ROOT}/Manifest.lock" > /dev/null
              if [[ $? != 0 ]] ; then
                  cat << EOM
              error: The sandbox is not in sync with the Podfile.lock. Run 'pod install'.
              EOM
                  exit 1
              fi
            EOS
          end
        end

        # Saves the changes to the user project to the disk.
        #
        # @return [void]
        #
        def save_user_project
          user_project.save_as(library.user_project_path)
        end

        #---------------------------------------------------------------------#

        # @!group Private helpers.

        private

        # Informs the user about any build setting of the target which might
        # override the given xcconfig file.
        #
        # @return [void]
        #
        def check_overridden_build_settings(xcconfig, target)
          return unless xcconfig

          configs_by_overridden_key = {}
          target.build_configurations.each do |config|
            xcconfig.attributes.keys.each do |key|
              target_value = config.build_settings[key]

              if target_value && !target_value.include?('$(inherited)')
                configs_by_overridden_key[key] ||= []
                configs_by_overridden_key[key] << config.name
              end
            end

            configs_by_overridden_key.each do |key, config_names|
              name    = "#{target.name} [#{config_names.join(' - ')}]"
              actions = [
                "Use the `$(inherited)` flag, or",
                "Remove the build settings from the target."
              ]
              UI.warn("The target `#{name}` overrides the `#{key}` build " \
                      "setting defined in `#{library.xcconfig_relative_path}'.",
                      actions)
            end
          end
        end

        # @return [String] the message that should be displayed for the target
        #         integration.
        #
        def integration_message
          "Integrating `#{library.product_name}` into " \
            "#{'target'.pluralize(targets.size)} "  \
            "`#{targets.map(&:name).to_sentence}` " \
            "of project #{UI.path library.user_project_path}."
        end

        #---------------------------------------------------------------------#

      end
    end
  end
end
