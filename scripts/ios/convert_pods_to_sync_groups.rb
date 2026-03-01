#!/usr/bin/env ruby
# frozen_string_literal: true

# Converts development pod source groups in Pods.xcodeproj from traditional
# PBXGroup + PBXFileReference to PBXFileSystemSynchronizedRootGroup.
#
# This allows Xcode to auto-discover source files without running `pod install`
# every time a file is added, renamed, or deleted in an expo module.
#
# Usage:
#   ruby convert_pods_to_sync_groups.rb <path/to/Pods.xcodeproj> [--pod PodName] [--dry-run]
#
# Run after `pod install`. The conversion is idempotent.

require 'xcodeproj'
require 'set'

# The xcodeproj gem doesn't expose a `name` attribute on PBXFileSystemSynchronizedRootGroup,
# but the pbxproj format supports it. Without it, Xcode uses the raw path as the display name.
Xcodeproj::Project::Object::PBXFileSystemSynchronizedRootGroup.class_eval do
  attribute :name, String

  def display_name
    return name if name
    return path if path
    super
  end
end

class PodSyncGroupConverter
  def initialize(project_path, options = {})
    @project = Xcodeproj::Project.open(project_path)
    @project_dir = File.dirname(@project.path)
    @target_pod = options[:pod]
    @dry_run = options[:dry_run] || false
    @verbose = options[:verbose] || false
  end

  def convert!
    dev_pods_group = @project.main_group.children.find { |g| g.display_name == 'Development Pods' }
    unless dev_pods_group
      puts "No 'Development Pods' group found in project."
      return
    end

    converted = 0

    dev_pods_group.children.to_a.each do |pod_group|
      next unless pod_group.isa == 'PBXGroup'
      next if @target_pod && pod_group.display_name != @target_pod

      # Skip pods that have already been converted
      if pod_group.isa == 'PBXFileSystemSynchronizedRootGroup'
        puts "#{pod_group.display_name}: already converted, skipping"
        next
      end

      # Only convert if this group has a path pointing to source files
      # (development pods have paths like ../../../../packages/expo-camera/ios)
      unless pod_group.path && !pod_group.path.empty?
        puts "#{pod_group.display_name}: no source path, skipping" if @verbose
        next
      end

      success = convert_pod_group(pod_group, dev_pods_group)
      converted += 1 if success
    end

    if converted > 0 && !@dry_run
      @project.save
      puts "\nSaved project. #{converted} pod(s) converted."
    elsif converted > 0
      puts "\n[DRY RUN] Would convert #{converted} pod(s)."
    else
      puts "\nNo pods to convert."
    end
  end

  private

  def convert_pod_group(pod_group, dev_pods_group)
    pod_name = pod_group.display_name
    source_path = pod_group.path
    source_tree = pod_group.source_tree

    target = @project.native_targets.find { |t| t.name == pod_name }
    unless target
      puts "#{pod_name}: no matching target found, skipping"
      return false
    end

    # Skip pods that have associated test targets (test specs)
    test_target = @project.native_targets.find { |t| t.name == "#{pod_name}-Unit-Tests" }
    if test_target
      puts "#{pod_name}: has a test spec target, skipping"
      return false
    end

    puts "Converting #{pod_name}..."
    puts "  Source path: #{source_path}" if @verbose

    # Separate children into source files/groups vs. special groups (Pod, Support Files)
    source_children = []
    special_groups = {}

    pod_group.children.to_a.each do |child|
      if child.isa == 'PBXGroup' && (child.display_name == 'Pod' || child.display_name == 'Support Files')
        special_groups[child.display_name] = child
      else
        source_children << child
      end
    end

    puts "  Source children: #{source_children.count}" if @verbose
    puts "  Special groups: #{special_groups.keys.join(', ')}" if @verbose

    if @dry_run
      puts "  [DRY RUN] Would convert #{source_children.count} file references to synchronized root group"
      return true
    end

    # Collect all PBXFileReferences that belong to the source tree
    source_file_refs = collect_file_refs(source_children)
    puts "  Total source file refs: #{source_file_refs.count}" if @verbose

    # Collect PBXBuildFile entries pointing to source file refs
    source_build_file_uuids = Set.new(source_file_refs.map(&:uuid))

    # Remove source files from build phases (Xcode will handle them via the synchronized group)
    removed_from_build_phase = 0
    target.build_phases.each do |phase|
      phase.files.to_a.each do |build_file|
        if build_file.file_ref && source_build_file_uuids.include?(build_file.file_ref.uuid)
          phase.files.delete(build_file)
          build_file.remove_from_project
          removed_from_build_phase += 1
        end
      end
    end
    puts "  Removed #{removed_from_build_phase} entries from build phases" if @verbose

    # Remove source file references and subgroups
    source_children.each { |child| remove_recursively(child) }

    # Determine exclusions (e.g. Tests/ directories)
    source_abs_path = File.expand_path(source_path, @project_dir)
    exclusions = determine_exclusions(source_abs_path)

    # Create the PBXFileSystemSynchronizedRootGroup named after the pod
    sync_group = @project.new(Xcodeproj::Project::Object::PBXFileSystemSynchronizedRootGroup)
    sync_group.path = source_path
    sync_group.source_tree = source_tree
    sync_group.name = pod_name

    # Create exception set if there are exclusions
    if exclusions.any?
      exception_set = @project.new(Xcodeproj::Project::Object::PBXFileSystemSynchronizedBuildFileExceptionSet)
      exception_set.target = target
      exception_set.membership_exceptions = exclusions
      sync_group.exceptions << exception_set
      puts "  Exclusions: #{exclusions.join(', ')}" if @verbose
    end

    # Register the synchronized group with the target
    target.file_system_synchronized_groups ||= []
    target.file_system_synchronized_groups << sync_group

    # Fix Support Files path: was relative to the old source directory,
    # now needs to be relative to the project directory (Development Pods has no path)
    support_files = special_groups['Support Files']
    if support_files
      old_support_abs = File.expand_path(support_files.path, source_abs_path)
      new_support_path = Pathname.new(old_support_abs).relative_path_from(Pathname.new(@project_dir)).to_s
      puts "  Support Files path: #{support_files.path} -> #{new_support_path}" if @verbose
      support_files.path = new_support_path
      support_files.name = "#{pod_name} Support Files"

      # Move Support Files out of the old group and into Development Pods as a sibling
      pod_group.children.delete(support_files)
      # Insert right after where the sync group will be
      idx = dev_pods_group.children.index(pod_group)
      dev_pods_group.children.insert(idx + 1, support_files)
    end

    # Remove the Pod subgroup (podspec is visible inside the synced directory)
    pod_subgroup = special_groups['Pod']
    pod_subgroup&.remove_from_project

    # Replace the old pod_group with the sync group in Development Pods.
    # Note: we can't use `children[idx] =` because ObjectList doesn't track index assignment.
    idx = dev_pods_group.children.index(pod_group)
    pod_group.remove_from_project
    dev_pods_group.children.insert(idx, sync_group)

    puts "  Converted successfully"
    true
  end

  def collect_file_refs(children)
    refs = []
    children.each do |child|
      case child.isa
      when 'PBXFileReference'
        refs << child
      when 'PBXGroup'
        refs.concat(collect_file_refs(child.children.to_a))
      end
    end
    refs
  end

  def remove_recursively(node)
    if node.isa == 'PBXGroup'
      node.children.to_a.each { |c| remove_recursively(c) }
    end
    node.remove_from_project
  end

  def determine_exclusions(source_abs_path)
    exclusions = []
    # Check for common directories that podspecs typically exclude
    ['Tests', 'tests'].each do |dir|
      exclusions << dir if Dir.exist?(File.join(source_abs_path, dir))
    end
    exclusions
  end
end

# --- CLI ---

if __FILE__ == $0
  require 'optparse'

  options = {}
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: #{$0} <path/to/Pods.xcodeproj> [options]"

    opts.on('--pod POD', 'Convert only the specified pod') do |pod|
      options[:pod] = pod
    end

    opts.on('--dry-run', 'Show what would be converted without making changes') do
      options[:dry_run] = true
    end

    opts.on('--verbose', 'Show detailed output') do
      options[:verbose] = true
    end

    opts.on('-h', '--help', 'Show this help') do
      puts opts
      exit
    end
  end

  parser.parse!
  project_path = ARGV[0]

  unless project_path
    puts parser.banner
    exit 1
  end

  unless File.exist?(project_path)
    puts "Project not found: #{project_path}"
    exit 1
  end

  converter = PodSyncGroupConverter.new(project_path, options)
  converter.convert!
end
