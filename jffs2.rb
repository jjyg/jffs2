#!/usr/bin/ruby

require 'zlib'

class JFFS2
	# Jffs2 is a sequence of nodes
	# nodes are a tlv
	# each node has a version number and inode number,
	# later nodes (vers) preempt earlier nodes
	# type can be data (metadata + file data in a range, may be compressed)
	# or dirent (dir inode nr + file name + file inode nr)
	# delete a file = remap name to point to inode 0
	# no use of flash oob data
	# inode nr and version nr never wrap

	TYPE_MASK = 0x0fff
	TYPE_DENT = 1
	TYPE_INO = 2

	# raw flash data (String)
	attr_accessor :raw
	# array of nodes: { :type, etc }
	attr_accessor :nodes
	def initialize(raw, endianness=:big)
		@raw = raw

		@nodes = []

		@hdr_pck = 'CCnNN'
		@ino_pck = 'NNNnnNNNNNNNCCnNNa*'
		@dent_pck = 'NNNNCCnNNa*'
		if endianness == :little
			@hdr_pck = @hdr_pck.gsub('n', 'v').gsub('N', 'V')
			@ino_pck = @ino_pck.gsub('n', 'v').gsub('N', 'V')
			@dent_pck = @dent_pck.gsub('n', 'v').gsub('N', 'V')
		end
	end

	def check_hdr_crc(*a)
		# TODO
		true
	end

	# read all nodes from the media
	def read_nodes
		# node header: 12 bytes
		# |   |   |   |   |
		# |19h|85h|  type |
		# |  node length  |	(incl hdr)
		# |   hdr crc     |

		off = 0
		while off < @raw.length
			rawhdr = @raw[off, 12]
			magic1, magic2, type, len, crc = rawhdr.unpack(@hdr_pck)
			if magic1 == 0x19 and magic2 == 0x85 and check_hdr_crc(rawhdr, crc)
				@nodes << parse_node(off, type, @raw[off+12, len-12])
				off += len
				if off & 3 != 0
					# keep hdr 32b-aligned
					padlen = 4 - (off & 3)
					@nodes.last.update(:pad => @raw[off, padlen])
					off += padlen
				end
			else
				# skip empty flash blocks (filled with 0xff)
				pad512 = 512 - (off & 0x1ff)
				if @raw[off, pad512].unpack('C*').uniq == [0xff]
					off += pad512
				else
					# try to resync
					puts "jffs2: bad node signature at #{'0x%X' % off} #{rawhdr.unpack('H*').first}"
					if idx = @raw[off, 1024].index([0x19, 0x85].pack('C*'))
						off += idx
					else
						off += 1024
					end
				end
			end
		end
	end

	def parse_node(off, type, raw)
		case type & TYPE_MASK
		when TYPE_INO
			{ :off => off, :type => type }.merge(parse_inode(raw))
		when TYPE_DENT
			{ :off => off, :type => type }.merge(parse_dentry(raw))
		else
			{ :off => off, :type => type, :raw => raw }
		end
	end

	def parse_inode(raw)
		# csize = compressed chunk data size, dsize = decompressed
		ino, version, mode, uid, gid, isize, atime, mtime, ctime, foff, csize, dsize, compr1, compr2, flags, data_crc, node_crc, data = raw.unpack(@ino_pck)
		{
			:ino => ino,
			:version => version,
			:mode => mode,
			:uid => uid,
			:gid => gid,
			:isize => isize,
			:atime => atime,
			:atime_a => Time.at(atime).utc.strftime("%Y-%m-%d %H:%M:%S Z"),
			:mtime => mtime,
			:mtime_a => Time.at(mtime).utc.strftime("%Y-%m-%d %H:%M:%S Z"),
			:ctime => ctime,
			:ctime_a => Time.at(ctime).utc.strftime("%Y-%m-%d %H:%M:%S Z"),
			:foff => foff,
			:csize => csize,
			:dsize => dsize,
			:compr1 => compr1,
			:compr2 => compr2,
			:flags => flags,
			:data_crc => data_crc,
			:node_crc => node_crc,
			:data => data,
		}
	end

	def parse_dentry(raw)
		pino, version, ino, mctime, nsize, itype, unk, node_crc, name_crc, name = raw.unpack(@dent_pck)
		{
			:pino => pino,
			:version => version,
			:ino => ino,
			:mctime => mctime,
			:mctime_a => Time.at(mctime).utc.strftime("%Y-%m-%d %H:%M:%S Z"),
			:nsize => nsize,
			:itype => itype,
			:unk => unk,
			:node_crc => node_crc,
			:name_crc => name_crc,
			:name => name[0, nsize],
			:name_pad => name[nsize..-1],
		}
	end

	attr_accessor :ino, :dent, :root_inos

	# rebuild the folder structure
	# populate @ino, @dent, @root_inos
	def rebuild_fs
		@ino = {}	# inode nr => [nodes]
		@dent = {}	# pino => [nodes]
		@nodes.each { |node|
			if node[:pino]
				(@dent[node[:pino]] ||= []) << node
			elsif node[:compr1]
				(@ino[node[:ino]] ||= []) << node
			end
		}

		@root_inos = @dent.keys - @dent.values.flatten.map { |node| node[:ino] }
	end

	# dump the @fs_tree to stdout
	# for each directory, list each name within with the associated inode numbers through time (0 = unlinked)
	def dump_fs_tree
		@root_inos.sort.each { |root|
			dump_fs_tree_rec(root)
		}
	end

	def dump_fs_tree_rec(pino, indent='')
		return if not @dent[pino]
		@dent[pino].map { |node| node[:name] }.uniq.sort.each { |name|
			inos = dent_sorted(pino).find_all { |node| node[:name] == name }.map { |node| node[:ino] }
			name += '/' if @dent[pino].find { |node| node[:name] == name and node[:itype] == 4 }
			puts "#{indent}#{name}  #{inos.join(' ')}"
			inos.each { |ino| dump_fs_tree_rec(ino, indent + '    ') }
		}
	end

	def dump_timeline
		lines = []
		@nodes.each { |node|
			case node[:type] & TYPE_MASK
			when TYPE_INO
				lines << [node[:atime], 'access', node[:ino], '', 0]
				lines << [node[:ctime], 'create', node[:ino], '', 0]
				lines << [node[:mtime], 'write', node[:ino], '', 0]
			when TYPE_DENT
				if node[:ino] == 0
					lines << [node[:mctime], 'delete', node[:ino], node[:name], node[:pino]]
				else
					lines << [node[:mctime], 'rename', node[:ino], node[:name], node[:pino]]
				end
			end
		}
		puts 'time,action,inode,name,parent_inode'
		puts lines.uniq.sort.map { |l| l.join(',') }
	end

	# return an array of nodes sorted by version
	def ino_sorted(ino)
		@ino[ino].to_a.sort_by { |node| node[:version] }
	end

	def dent_sorted(pino)
		@dent[pino].to_a.sort_by { |node| node[:version] }
	end

	# extract the various content of an inode through time
	# each state is stored in ino_<inode_nr>_<file_names>/<serial_state_nr>
	# save the log in <dir>/log
	def extract_file_history(ino)
		serial_nr = 0
		ranges = []	# file data indexes that are not yet dumped to disk
		raw = ''	# raw file data

		clean_name = lambda { |n|
			n.gsub(/[^a-zA-Z0-9_.-]/) { |o| o.unpack('H*').first }
		}

		all_names = []
		@dent.each_value { |dt|
			dt.sort_by { |node| node[:version] }.each { |node|
				next if node[:ino] != ino
				n = clean_name[node[:name]]
				all_names << n if all_names.last != n
			}
		}

		dirname = "ino_#{ino}_#{all_names.join('_')}"
		Dir.mkdir(dirname) rescue nil	# raise if already exists
		puts dirname

		dent_sorted(ino).each { |node|
			File.open(File.join(dirname, 'log'), 'a') { |fd| fd.puts node.inspect }
		}

		range_intersect = lambda { |cur_range|
			co, cl = cur_range
			ranges.find { |o, l|
				(o >= co and o < co+cl) or
				(co >= o and co < o+l) or
				(o+l > co and o+l < co+cl) or
				(co+cl > o and co+cl < o+l)
			}
		}

		dump = lambda {
			curname = '%04d' % serial_nr
			File.open(File.join(dirname, 'log'), 'a') { |fd| fd.puts "dumping #{curname}" }
			File.open(File.join(dirname, curname), 'wb') { |fd| fd.write raw }
			serial_nr += 1
			ranges.clear
		}

		ranges << [-1, 0]	# ensure we dump empty files too

		ino_sorted(ino).each { |node|
			File.open(File.join(dirname, 'log'), 'a') { |fd| fd.puts node.inspect }
			cur_range = [node[:foff], node[:dsize]]
			cur_data = jffs_decompress(node)
			if cur_data.length != node[:dsize]
				puts "jffs: bad file data #{cur_data.length} #{cur_data[-5, 5].inspect} #{node.inspect}"
			end

			# cur data overwrite previous data: dump previous to file
			dump[] if range_intersect[cur_range]

			if cur_range[0] > raw.length
				# write after end of file, pad with 0
				padlen = cur_range[0] - raw.length
				ranges << [raw.length, padlen]
				raw << ([0] * padlen).pack('C*')
			end

			# update raw data
			raw[cur_range[0], cur_range[1]] = cur_data
			ranges << cur_range if cur_range[1] != 0

			if node[:isize] < raw.length
				# file is truncated: dump if would discard some data
				dump[]
				raw = raw[0, node[:isize]]
			end
		}
		dump[] if not ranges.empty?
	end

	def jffs_decompress(node)
		case node[:compr1]
		when 0
			node[:data]
		when 6
			jffs_decompress_zlib(node)
		when 8
			jffs_decompress_lzma(node)
		else
			puts "jffs: unsupported compression method #{node[:compr1]}"
			node[:data]
		end
	end

	def jffs_decompress_zlib(node)
		data = node[:data]
		wbits = 15
		b0, b1 = data.unpack('CC')
		if data.length > 2 and (b1 & 0x20) == 0 and (b0 & 0x0f) == 8 and ((b0 << 8) + b1) % 31 == 0
			wbits = -((b0 >> 4) + 8)
			data = data[2..-1]
		end
		i = Zlib::Inflate.new(wbits)
		data = i.inflate(data)
		i.close
		data
	end

	def jffs_decompress_lzma(node)
		data = node[:data]
		# decompressor parameters from lzma jffs2 patch for linux kernel from openwrt
		dec = IO.popen('xz -c -d -F raw -qq --lzma1=lp=0,lc=0,pb=0,dict=8192', 'r+b') { |fd|
			fd.write data
			fd.close_write
			fd.read
		}
		if dec.length > node[:dsize] and dec[node[:dsize] - dec.length, dec.length - node[:dsize]].unpack('C*').uniq == [0]
			# discard trailing nuls
			dec = dec[0, node[:dsize]]
		end
		dec
	end

	# turn a jffs2 dump generated with 'jffs2.rb -a'
	# eg ino_123_toto.txt/0000
	# into an actual fs tree, eg root/tmp/toto.txt_123_0000
	def fulldump_to_tree
		all = []

		Dir['ino_*'].sort.each { |oid|
			next if oid !~ /ino_(\d+)_/
			ino = $1.to_i

			(Dir.entries(oid) - ['.', '..', 'log']).sort.each { |ent|
				if ent !~ /^(\d+)$/
					puts "unk entry #{id} #{ent}"
					next
				end
				idx = $1.to_i

				all << ["#{oid}/#{ent}", ino, idx]
			}
		}
		abort 'run with -a beforehand' if all.empty?

		rec = lambda { |curino, curpath, curpino|
			cur = all.find_all { |path, ino, idx| ino == curino }
			name = dent_sorted(curpino).find_all { |node| node[:ino] == curino }.map { |node| node[:name] }.last || 'root'

			if not @dent[curino]
				# file
				cur.each { |path, ino, idx|
					File.link(path, File.join(curpath, "#{name}_#{ino}_#{'%04d' % idx}"))
				}
			else
				# directory
				subdir = File.join(curpath, "#{name}_#{curino}")
				Dir.mkdir(subdir) rescue nil
				puts subdir
				dent_sorted(curino).map { |node| node[:ino] }.uniq.each { |ino| rec[ino, subdir, curino] if ino != 0 }
			end
		}

		@root_inos.each { |r| rec[r, '.', -1] }
	end

	# prevent ruby crash when raising an exception
	def inspect
		"#<JFFS2>"
	end
end

if $0 == __FILE__
	tg = ARGV.shift
	abort "usage: jffs2 <dumpfile> [<obj_id>|-a|-r]" if not File.exist?(tg)

	ino_nr = ARGV.shift

	raw = File.open(tg, 'rb') { |fd| fd.read }

	jffs = JFFS2.new(raw)
	jffs.read_nodes
	jffs.rebuild_fs

	case ino_nr
	when nil
		jffs.dump_fs_tree
	when '-a'
		jffs.ino.keys.sort.each { |ino| jffs.extract_file_history(ino) }
	when '-r'
		jffs.fulldump_to_tree
	when '-t'
		jffs.dump_timeline
	when /^\d+$/
		ino_nr = ino_nr.to_i
		if $VERBOSE
			jffs.dent_sorted(ino_nr).each { |n| p n }
			jffs.ino_sorted(ino_nr).each { |n| p n }
		end
		jffs.extract_file_history(ino_nr)
	else
		puts "usage: jffs2 <dumpfile> [<obj_id>|-a|-r|-t]"
	end
end
